"""
GET /v1/leaderboard?scope=memphis%23all&limit=50

Returns the ranked leaderboard from the leaderboard_snapshot table.

Design decisions:
- Reads exclusively from leaderboard_snapshot — never scans the ratings table
  directly. This decouples read performance from write volume. A hot leaderboard
  route scanning all ratings would become a cost and latency problem at scale.
- Response includes a `version` field (ISO 8601 timestamp of last recompute).
  This enables polling clients to detect staleness and is the prerequisite for
  a future push/WebSocket upgrade — no schema change needed.
- scope defaults to "memphis#all" — the partition that covers the full city
  leaderboard. Future scopes (e.g., "memphis#bbq", "nashville#all") can be
  added without changing the table schema.
- limit defaults to 50; max is 100. Clients should not page through the full
  table — the leaderboard is a denormalized snapshot, not a raw query target.
- Items are already stored rank-ordered (rank is the sort key, type N) so no
  client-side sort is needed.

Security:
- JWT authorizer on the route; user_sub is extracted for logging only.
  The leaderboard is read-only and contains no user PII — only restaurant IDs
  and aggregated scores.
"""

import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key

from shared.auth import get_user_sub

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
leaderboard_snapshot_table = dynamodb.Table(os.environ["LEADERBOARD_SNAPSHOT_TABLE"])

ROUTE = "GET /v1/leaderboard"
DEFAULT_SCOPE = "memphis#all"
DEFAULT_LIMIT = 50
MAX_LIMIT = 100


def _error(status_code, message):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"message": message}),
    }


def handler(event, context):
    start = time.monotonic()
    user_sub = get_user_sub(event)

    # --- Parse query parameters ---
    query_params = event.get("queryStringParameters") or {}
    scope = query_params.get("scope", DEFAULT_SCOPE)

    try:
        limit = min(int(query_params.get("limit", DEFAULT_LIMIT)), MAX_LIMIT)
        if limit < 1:
            raise ValueError
    except (TypeError, ValueError):
        return _error(400, "limit must be a positive integer")

    try:
        # Query leaderboard_snapshot by scope (PK). Items are returned in rank
        # order (SK ascending) by default — rank 1 first.
        response = leaderboard_snapshot_table.query(
            KeyConditionExpression=Key("scope").eq(scope),
            Limit=limit,
        )
        items = response.get("Items", [])

        # version comes from the stored attribute on leaderboard items.
        # Falls back to current timestamp when the leaderboard is empty
        # (no ratings submitted yet) — ensures the version field is always present.
        if items:
            version = items[0].get("version", datetime.now(timezone.utc).isoformat())
        else:
            version = datetime.now(timezone.utc).isoformat()

        leaderboard = [
            {
                "rank": int(item["rank"]),
                "restaurant_id": item["restaurant_id"],
                "bayesian_score": float(item["bayesian_score"]),
                "rating_count": int(item["rating_count"]),
                "algorithm_version": item.get("algorithm_version", "unknown"),
            }
            for item in items
        ]

        latency_ms = round((time.monotonic() - start) * 1000)
        logger.info(json.dumps({
            "level": "INFO",
            "message": "get_leaderboard success",
            "route": ROUTE,
            "userSub": user_sub,
            "requestId": event.get("requestContext", {}).get("requestId"),
            "statusCode": 200,
            "latencyMs": latency_ms,
            "scope": scope,
            "resultCount": len(leaderboard),
        }))

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({
                "leaderboard": leaderboard,
                "version": version,
                "scope": scope,
            }),
        }

    except Exception as exc:
        latency_ms = round((time.monotonic() - start) * 1000)
        logger.error(json.dumps({
            "level": "ERROR",
            "message": f"get_leaderboard error: {exc}",
            "route": ROUTE,
            "userSub": user_sub,
            "requestId": event.get("requestContext", {}).get("requestId"),
            "statusCode": 500,
            "latencyMs": latency_ms,
        }))
        return _error(500, "internal server error")
