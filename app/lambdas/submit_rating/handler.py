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
- Leaderboard recompute delegates to shared.leaderboard.recompute_leaderboard(),
  which is also used by admin_delete_restaurant. The upgrade path to DynamoDB
  Streams → aggregator Lambda requires no data model change — only the trigger.
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

import boto3

from shared.auth import get_user_sub
from shared.leaderboard import recompute_leaderboard

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Module-level clients — reused across warm invocations.
dynamodb = boto3.resource("dynamodb")
restaurants_table = dynamodb.Table(os.environ["RESTAURANTS_TABLE"])
ratings_table = dynamodb.Table(os.environ["RATINGS_TABLE"])
rating_events_table = dynamodb.Table(os.environ["RATING_EVENTS_TABLE"])

ROUTE = "POST /v1/ratings"


def _error(status_code, message):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"message": message}),
    }



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
        recompute_leaderboard()

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
