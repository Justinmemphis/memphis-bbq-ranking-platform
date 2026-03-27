"""
POST /v1/ratings
Upserts the caller's rating for a restaurant and appends an audit event.

Design decisions:
- ratings table uses PK=user_id (Cognito sub) + SK=restaurant_id. The PutItem
  call acts as an upsert — DynamoDB overwrites the item if the PK+SK already
  exists, enforcing the one-rating-per-user-per-restaurant constraint at the
  DB level. No conditional expression needed for the upsert itself.
- rating_events is append-only. Each submission writes a new event regardless
  of whether this is a create or update. created_at is ISO 8601 UTC, which is
  lexicographically sortable as the sort key.
- Leaderboard recompute is a stub (pass) for now. Saturday's sprint wires the
  Bayesian average inline call here.
- score is validated as an integer in [1, 5] before touching DynamoDB.
  restaurant_id is validated as non-empty. No other fields are accepted —
  extra keys in the request body are silently ignored.

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

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Module-level clients — reused across warm invocations.
dynamodb = boto3.resource("dynamodb")
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

        # Leaderboard recompute — stub for now; wired in Sprint 10 (Saturday).
        # _recompute_leaderboard(restaurant_id)

        latency_ms = round((time.monotonic() - start) * 1000)
        logger.info(json.dumps({
            "level": "INFO",
            "message": "submit_rating success",
            "route": ROUTE,
            "userSub": user_sub,
            "requestId": context.aws_request_id,
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
            "requestId": context.aws_request_id,
            "statusCode": 500,
            "latencyMs": latency_ms,
            "restaurantId": restaurant_id,
        }))
        return _error(500, "internal server error")
