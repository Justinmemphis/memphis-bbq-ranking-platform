"""
POST /v1/ratings
Upserts the caller's rating for a restaurant, appends an audit event,
and synchronously recomputes the leaderboard (Bayesian average).

Design decisions:
- ratings table uses PK=user_id (Cognito sub) + SK=restaurant_id. The PutItem
  call acts as an upsert — DynamoDB overwrites the item if the PK+SK already
  exists, enforcing the one-rating-per-user-per-restaurant constraint at the
  DB level. No conditional expression needed for the upsert itself.
- rating_events is append-only. Each submission writes a new event regardless
  of whether this is a create or update. created_at is ISO 8601 UTC, which is
  lexicographically sortable as the sort key.
- Leaderboard recompute is an inline synchronous call (see _recompute_leaderboard).
  The upgrade path to DynamoDB Streams → aggregator Lambda requires no data model
  change — only the trigger mechanism changes.
- score is validated as an integer in [1, 5] before touching DynamoDB.
  restaurant_id is validated as non-empty. No other fields are accepted —
  extra keys in the request body are silently ignored.
- Restaurant existence is verified (GetItem) before writing the rating.
  A rating for a non-existent restaurant returns 404. This prevents orphaned
  ratings that would silently appear on the leaderboard.

Security:
- user_sub is sourced from the JWT claims set by API Gateway — not from the
  request body. A caller cannot forge another user's sub.
- Input validation rejects out-of-range scores and missing restaurant_id
  before any DynamoDB write occurs.
"""

import json
import logging
import os
import time
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

from shared.auth import get_user_sub

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Module-level clients — reused across warm invocations.
dynamodb = boto3.resource("dynamodb")
restaurants_table = dynamodb.Table(os.environ["RESTAURANTS_TABLE"])
ratings_table = dynamodb.Table(os.environ["RATINGS_TABLE"])
rating_events_table = dynamodb.Table(os.environ["RATING_EVENTS_TABLE"])
leaderboard_snapshot_table = dynamodb.Table(os.environ["LEADERBOARD_SNAPSHOT_TABLE"])

ROUTE = "POST /v1/ratings"

# Leaderboard constants.
LEADERBOARD_SCOPE = "memphis#all"

# Bayesian average parameters.
# C = prior weight: equivalent to this many "neutral" ratings anchoring toward the mean.
# A small value (5) means a restaurant with just a few ratings won't rocket to the top,
# but a restaurant with 20+ real ratings will converge toward its true mean.
# m = prior mean: the neutral midpoint of the 1-5 scale.
# Algorithm version is stored on each leaderboard item so future changes are traceable.
BAYESIAN_C = Decimal("5")
BAYESIAN_M = Decimal("3")
ALGORITHM_VERSION = "bayesian-v1"


def _error(status_code, message):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"message": message}),
    }


def _recompute_leaderboard():
    """
    Recomputes the leaderboard_snapshot table using a Bayesian average.

    What it does:
    1. Scans all ratings to aggregate count and sum per restaurant.
    2. Computes Bayesian score: (C*m + sum) / (C + n) per restaurant.
       This pulls low-count restaurants toward the prior mean rather than
       letting a single 5-star rating dominate the top of the list.
    3. Sorts descending by Bayesian score, assigns rank (1 = best).
    4. Deletes stale leaderboard items (in case restaurant count shrinks).
    5. Writes fresh ranked items to leaderboard_snapshot.

    The scope key "memphis#all" is the partition for the full city leaderboard.
    Future scopes (e.g., "memphis#bbq", "nashville#all") can be added without
    changing this table's schema.

    Inline call trade-off:
    - Simple, no additional AWS services.
    - Full table scan on ratings on every write — acceptable at MVP scale.
    - DynamoDB Streams → Lambda upgrade path: replace this function call with
      a stream-triggered Lambda; data model is unchanged.

    Security: this function runs under submit_rating's IAM role, which is
    scoped to Scan on ratings and Query/DeleteItem/PutItem on leaderboard_snapshot.
    No other tables are accessible.
    """
    # Step 1: Scan all ratings and aggregate per restaurant.
    # Scan is necessary because there is no GSI on restaurant_id for the ratings table.
    # At MVP scale this is acceptable. The Streams upgrade eliminates the scan.
    aggregates = {}  # {restaurant_id: {"n": count, "sum": Decimal(sum)}}

    paginator_kwargs = {}
    while True:
        response = ratings_table.scan(
            ProjectionExpression="restaurant_id, score",
            **paginator_kwargs,
        )
        for item in response.get("Items", []):
            rid = item["restaurant_id"]
            score = Decimal(str(item["score"]))
            if rid not in aggregates:
                aggregates[rid] = {"n": 0, "sum": Decimal("0")}
            aggregates[rid]["n"] += 1
            aggregates[rid]["sum"] += score

        last_key = response.get("LastEvaluatedKey")
        if not last_key:
            break
        paginator_kwargs["ExclusiveStartKey"] = last_key

    if not aggregates:
        # No ratings yet — leaderboard stays empty.
        return

    # Step 2: Compute Bayesian score for each restaurant.
    scored = []
    for rid, agg in aggregates.items():
        n = Decimal(str(agg["n"]))
        total = agg["sum"]
        bayesian_score = (BAYESIAN_C * BAYESIAN_M + total) / (BAYESIAN_C + n)
        scored.append({
            "restaurant_id": rid,
            "bayesian_score": bayesian_score,
            "rating_count": int(n),
            "rating_sum": int(total),
        })

    # Step 3: Sort descending by Bayesian score; ties broken by more ratings.
    scored.sort(key=lambda x: (x["bayesian_score"], x["rating_count"]), reverse=True)

    version = datetime.now(timezone.utc).isoformat()

    # Step 4: Delete existing leaderboard items so stale ranks are removed.
    # Query (not Scan) — scope is the partition key, so this is efficient.
    existing = leaderboard_snapshot_table.query(
        KeyConditionExpression=Key("scope").eq(LEADERBOARD_SCOPE),
        ProjectionExpression="#r",
        ExpressionAttributeNames={"#r": "rank"},
    )
    for item in existing.get("Items", []):
        leaderboard_snapshot_table.delete_item(
            Key={"scope": LEADERBOARD_SCOPE, "rank": item["rank"]},
        )

    # Step 5: Write fresh ranked items.
    # rank is 1-indexed (1 = best). Stored as a number (SK type N in schema).
    with leaderboard_snapshot_table.batch_writer() as batch:
        for i, entry in enumerate(scored, start=1):
            batch.put_item(Item={
                "scope": LEADERBOARD_SCOPE,
                "rank": i,
                "restaurant_id": entry["restaurant_id"],
                "bayesian_score": entry["bayesian_score"].quantize(Decimal("0.0001")),
                "rating_count": entry["rating_count"],
                "algorithm_version": ALGORITHM_VERSION,
                "version": version,
            })


def handler(event, context):
    start = time.monotonic()
    user_sub = get_user_sub(event)

    # --- Parse and validate request body ---
    try:
        body = json.loads(event.get("body") or "{}")
    except (json.JSONDecodeError, TypeError):
        return _error(400, "invalid JSON body")

    restaurant_id = body.get("restaurant_id", "").strip()
    if not restaurant_id:
        return _error(400, "restaurant_id is required")

    raw_score = body.get("score")
    try:
        score = int(raw_score)
        if score < 1 or score > 5:
            raise ValueError
    except (TypeError, ValueError):
        return _error(400, "score must be an integer between 1 and 5")

    # --- Restaurant existence check ---
    # Prevents ratings for restaurants that don't exist. Without this, a caller
    # could submit ratings for arbitrary IDs, which would surface on the leaderboard
    # with no corresponding restaurant record.
    restaurant_resp = restaurants_table.get_item(
        Key={"restaurant_id": restaurant_id},
        ProjectionExpression="restaurant_id",
    )
    if "Item" not in restaurant_resp:
        return _error(404, f"restaurant '{restaurant_id}' not found")

    # --- Write to DynamoDB ---
    now = datetime.now(timezone.utc).isoformat()

    try:
        # Upsert rating — PK+SK combo enforces one rating per user per restaurant.
        # PutItem overwrites the existing item if it exists (update semantics).
        ratings_table.put_item(Item={
            "user_id": user_sub,
            "restaurant_id": restaurant_id,
            "score": score,
            "updated_at": now,
        })

        # Append audit event — written regardless of create vs. update.
        # created_at is the SK; ISO 8601 UTC is lexicographically sortable.
        rating_events_table.put_item(Item={
            "restaurant_id": restaurant_id,
            "created_at": now,
            "user_id": user_sub,
            "score": score,
        })

        # Inline leaderboard recompute — Bayesian average over all ratings.
        # Upgrade path: swap this call for a DynamoDB Streams trigger; data model unchanged.
        _recompute_leaderboard()

        latency_ms = round((time.monotonic() - start) * 1000)
        logger.info(json.dumps({
            "level": "INFO",
            "message": "submit_rating success",
            "route": ROUTE,
            "userSub": user_sub,
            "requestId": event.get("requestContext", {}).get("requestId"),
            "statusCode": 200,
            "latencyMs": latency_ms,
            "restaurantId": restaurant_id,
        }))

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({
                "message": "rating submitted",
                "restaurant_id": restaurant_id,
                "score": score,
            }),
        }

    except Exception as exc:
        latency_ms = round((time.monotonic() - start) * 1000)
        logger.error(json.dumps({
            "level": "ERROR",
            "message": f"submit_rating error: {exc}",
            "route": ROUTE,
            "userSub": user_sub,
            "requestId": event.get("requestContext", {}).get("requestId"),
            "statusCode": 500,
            "latencyMs": latency_ms,
            "restaurantId": restaurant_id,
        }))
        return _error(500, "internal server error")
