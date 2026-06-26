#!/usr/bin/env python3
"""
Seed script: populate DynamoDB restaurants table from Google Places API.

Searches "BBQ restaurants in Shelby County TN", fetches Place Details per result,
and writes directly to DynamoDB (bypassing the admin API — script runs with your
local AWS credentials, same role used for Terraform).

Usage:
    PLACES_API_KEY=<key> python scripts/seed_from_places.py [--env dev|prod] [--dry-run]

Cost: ~$0.032/Text Search page + ~$0.017/Place Details call. Negligible for a one-time seed.

Security:
    API key read from PLACES_API_KEY env var — never hardcoded.
    Never run against prod without explicit intent (--env prod requires confirmation).
    put_item overwrites existing records — existing curated data (notes, style) will
    be replaced. Run seed_restaurants.py afterwards to re-apply curated overrides.
"""

import argparse
import os
import re
import sys
import time
from datetime import datetime, timezone

import boto3
import requests
from botocore.exceptions import ClientError

PLACES_TEXT_SEARCH = "https://maps.googleapis.com/maps/api/place/textsearch/json"
PLACES_DETAILS = "https://maps.googleapis.com/maps/api/place/details/json"
DETAIL_FIELDS = "name,formatted_address,formatted_phone_number,website,geometry,address_components"

SEARCH_QUERIES = [
    # Broad sweeps
    "BBQ restaurants in Shelby County TN",
    "barbecue restaurants Memphis TN",
    # Geographic area sweeps to catch suburban locations missed by city-center results
    "BBQ restaurants Germantown TN",
    "BBQ restaurants Bartlett TN",
    "BBQ restaurants Cordova TN",
    "BBQ restaurants Collierville TN",
    "BBQ restaurants Millington TN",
    "BBQ restaurants Arlington TN",
    # Chain-specific searches to ensure all individual locations are captured
    "Tops BBQ Memphis TN",
    "Corky's Ribs BBQ Memphis TN",
    "One and Only BBQ Memphis TN",
    "Central BBQ Memphis TN",
    "Jim Neely's Interstate Bar-B-Que Memphis TN",
    "Marlowe's Ribs Restaurant Memphis TN",
    "Memphis BBQ Company Memphis TN",
]


def slugify(name: str) -> str:
    s = name.lower()
    s = re.sub(r"['‘’‚‛`]", "", s)
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = s.strip("-")
    return s


def fetch_query(api_key: str, query: str) -> list[dict]:
    """Fetch all pages for a single query string."""
    results = []
    params = {"query": query, "key": api_key}

    while True:
        resp = requests.get(PLACES_TEXT_SEARCH, params=params, timeout=15)
        resp.raise_for_status()
        data = resp.json()

        status = data.get("status")
        if status in ("ZERO_RESULTS", "INVALID_REQUEST"):
            # INVALID_REQUEST on a next_page_token call is a known legacy Places API quirk;
            # accept whatever we have rather than crashing.
            break
        if status != "OK":
            print(f"  Places API error: {status} — {data.get('error_message', '')}")
            break

        batch = data.get("results", [])
        results.extend(batch)
        print(f"  Page fetched: {len(batch)} results (running total: {len(results)})")

        next_token = data.get("next_page_token")
        if not next_token:
            break

        # Google requires a delay before next_page_token becomes valid
        time.sleep(3)
        params = {"pagetoken": next_token, "key": api_key}

    return results


def fetch_all_places(api_key: str) -> list[dict]:
    seen_place_ids: set[str] = set()
    all_results = []

    for query in SEARCH_QUERIES:
        print(f'Searching: "{query}"')
        for place in fetch_query(api_key, query):
            pid = place.get("place_id")
            if pid and pid not in seen_place_ids:
                seen_place_ids.add(pid)
                all_results.append(place)

    return all_results


def fetch_details(api_key: str, place_id: str) -> dict:
    params = {"place_id": place_id, "fields": DETAIL_FIELDS, "key": api_key}
    resp = requests.get(PLACES_DETAILS, params=params, timeout=15)
    resp.raise_for_status()
    data = resp.json()

    if data.get("status") != "OK":
        return {}
    return data.get("result", {})


def extract_component(address_components: list, *types: str) -> str:
    for comp in address_components:
        if any(t in comp.get("types", []) for t in types):
            return comp.get("long_name", "")
    return ""


def extract_short_component(address_components: list, *types: str) -> str:
    for comp in address_components:
        if any(t in comp.get("types", []) for t in types):
            return comp.get("short_name", "")
    return ""


def extract_street_slug(address_components: list) -> str:
    """Return a slug suffix from the street name, e.g. 'summer-ave'."""
    route = extract_component(address_components, "route")
    return slugify(route) if route else ""


def build_item(place_id: str, detail: dict) -> dict | None:
    name = detail.get("name", "").strip()
    if not name:
        return None

    address_components = detail.get("address_components", [])

    # Filter to Tennessee only — exclude Mississippi (Southaven) and other states.
    state = extract_short_component(address_components, "administrative_area_level_1")
    if state and state != "TN":
        print(f"  SKIP out-of-state ({state}): {name!r}")
        return None

    # Skip corporate offices and non-restaurant entries.
    if any(kw in name.lower() for kw in ("corporate office", "corporate offices", "headquarters")):
        print(f"  SKIP non-restaurant: {name!r}")
        return None

    base_slug = slugify(name)

    # Slug must satisfy the same regex used by admin_create_restaurant:
    # lowercase alphanumeric + hyphens, no leading/trailing hyphens, min 3 chars.
    if not re.match(r"^[a-z0-9][a-z0-9\-]+[a-z0-9]$", base_slug):
        print(f"  SKIP slug invalid: '{base_slug}' (name: {name!r})")
        return None

    location = detail.get("geometry", {}).get("location", {})
    neighborhood = extract_component(address_components, "neighborhood", "sublocality_level_1")
    now = datetime.now(timezone.utc).isoformat()

    item = {
        "restaurant_id": base_slug,  # may be updated below if collision
        "name": name,
        "place_id": place_id,
        "created_at": now,
        "updated_at": now,
    }

    for field, value in [
        ("address", detail.get("formatted_address", "")),
        ("neighborhood", neighborhood),
        ("phone", detail.get("formatted_phone_number", "")),
        ("website", detail.get("website", "")),
        ("lat", str(location.get("lat", ""))),
        ("lng", str(location.get("lng", ""))),
        ("_street_slug", extract_street_slug(address_components)),  # temp field for collision resolution
    ]:
        if value:
            item[field] = value

    return item


def resolve_slug(item: dict, seen_slugs: set[str]) -> str | None:
    """Return a unique slug for the item, disambiguating by street name if needed."""
    base = item["restaurant_id"]
    if base not in seen_slugs:
        return base

    street = item.pop("_street_slug", "")
    if street:
        candidate = f"{base}-{street}"
        if re.match(r"^[a-z0-9][a-z0-9\-]+[a-z0-9]$", candidate) and candidate not in seen_slugs:
            return candidate

    # Last resort: append incrementing suffix
    for i in range(2, 20):
        candidate = f"{base}-{i}"
        if candidate not in seen_slugs:
            return candidate

    return None


def seed(env: str, api_key: str, dry_run: bool = False) -> None:
    places = fetch_all_places(api_key)
    print(f"\n{len(places)} places found — fetching details...")

    items = []
    seen_slugs: set[str] = set()

    for place in places:
        place_id = place.get("place_id")
        if not place_id:
            continue

        detail = fetch_details(api_key, place_id)
        if not detail:
            print(f"  SKIP no detail returned for place_id {place_id}")
            continue

        item = build_item(place_id, detail)
        if not item:
            continue

        slug = resolve_slug(item, seen_slugs)
        if not slug:
            print(f"  SKIP could not resolve unique slug for: {item.get('name')}")
            continue

        item["restaurant_id"] = slug
        item.pop("_street_slug", None)  # remove temp field before writing
        seen_slugs.add(slug)
        items.append(item)
        print(f"  {slug:<50} {item.get('name', '')}")

        time.sleep(0.1)  # light rate limiting between Detail calls

    print(f"\n{len(items)} items ready → bbq-{env}-restaurants")

    if dry_run:
        print("[dry-run] No writes performed.")
        return

    if env == "prod":
        confirm = input("WARNING: writing to PROD. Type 'yes' to continue: ")
        if confirm.strip().lower() != "yes":
            print("Aborted.")
            sys.exit(0)

    dynamodb = boto3.resource("dynamodb", region_name="us-east-1")
    table = dynamodb.Table(f"bbq-{env}-restaurants")

    ok = err = 0
    for item in items:
        try:
            table.put_item(Item=item)
            ok += 1
        except ClientError as e:
            print(f"  ERR {item['restaurant_id']}: {e.response['Error']['Message']}")
            err += 1

    print(f"\nDone: {ok} written, {err} errors.")
    if ok:
        print("Tip: run `python scripts/seed_restaurants.py` to re-apply curated overrides (style, notes).")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Seed restaurants from Google Places API.")
    parser.add_argument("--env", choices=["dev", "prod"], default="dev")
    parser.add_argument("--dry-run", action="store_true", help="Fetch from API but skip DynamoDB writes")
    args = parser.parse_args()

    api_key = os.environ.get("PLACES_API_KEY")
    if not api_key:
        print("Error: PLACES_API_KEY environment variable is not set.")
        sys.exit(1)

    seed(args.env, api_key, dry_run=args.dry_run)
