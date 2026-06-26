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
    "BBQ restaurants in Shelby County TN",
    "barbecue restaurants Memphis TN",
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


def extract_neighborhood(address_components: list) -> str:
    for comp in address_components:
        types = comp.get("types", [])
        if "neighborhood" in types or "sublocality_level_1" in types:
            return comp.get("long_name", "")
    return ""


def build_item(place_id: str, detail: dict) -> dict | None:
    name = detail.get("name", "").strip()
    if not name:
        return None

    slug = slugify(name)

    # Slug must satisfy the same regex used by admin_create_restaurant:
    # lowercase alphanumeric + hyphens, no leading/trailing hyphens, min 3 chars.
    if not re.match(r"^[a-z0-9][a-z0-9\-]+[a-z0-9]$", slug):
        print(f"  SKIP slug invalid: '{slug}' (name: {name!r})")
        return None

    location = detail.get("geometry", {}).get("location", {})
    address_components = detail.get("address_components", [])
    now = datetime.now(timezone.utc).isoformat()

    item = {
        "restaurant_id": slug,
        "name": name,
        "place_id": place_id,
        "created_at": now,
        "updated_at": now,
    }

    for field, value in [
        ("address", detail.get("formatted_address", "")),
        ("neighborhood", extract_neighborhood(address_components)),
        ("phone", detail.get("formatted_phone_number", "")),
        ("website", detail.get("website", "")),
        ("lat", str(location.get("lat", ""))),
        ("lng", str(location.get("lng", ""))),
    ]:
        if value:
            item[field] = value

    return item


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

        slug = item["restaurant_id"]
        if slug in seen_slugs:
            print(f"  SKIP duplicate slug: {slug}")
            continue

        seen_slugs.add(slug)
        items.append(item)
        print(f"  {slug:<45} {item.get('name', '')}")

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
