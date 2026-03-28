"""
GET /v1/restaurants/{restaurant_id}

Returns a single restaurant record by its stable slug ID.

Design decisions:
- restaurant_id is a stable slug (e.g., "paynes-bar-b-que") set at creation
  time and never changed. Using a mutable field like display name as the key
  would break all ratings and leaderboard entries on rename.
- 404 is returned for unknown IDs with a generic message — no distinction
  between "never existed" and "deleted" to avoid information leakage about
  the restaurant inventory.
- Input validation rejects blank or missing restaurant_id before hitting
  DynamoDB (saves a read unit on obviously invalid requests).

Security:
- JWT authorizer on the route. user_sub extracted for logging; not used in the
  query — this is a public-read endpoint within the authenticated API.
- GetItem (not Scan) — caller cannot enumerate restaurants via this route;
  they must know the restaurant_id.
"""

import json
import logging
import os
import time

import boto3

from shared.auth import get_user_sub

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
restaurants_table = dynamodb.Table(os.environ["RESTAURANTS_TABLE"])

ROUTE = "GET /v1/restaurants/{restaurant_id}"


def _error(status_code, message):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"message": message}),
    }


def handler(event, context):
    start = time.monotonic()
    user_sub = get_user_sub(event)

    restaurant_id = (event.get("pathParameters") or {}).get("restaurant_id", "").strip()
    if not restaurant_id:
        return _error(400, "restaurant_id is required")

    try:
        response = restaurants_table.get_item(Key={"restaurant_id": restaurant_id})
        item = response.get("Item")

        if item is None:
            latency_ms = round((time.monotonic() - start) * 1000)
            logger.info(json.dumps({
                "level": "INFO",
                "message": "get_restaurant_detail not found",
                "route": ROUTE,
                "userSub": user_sub,
                "requestId": context.aws_request_id,
                "statusCode": 404,
                "latencyMs": latency_ms,
                "restaurantId": restaurant_id,
            }))
            return _error(404, f"restaurant '{restaurant_id}' not found")

        latency_ms = round((time.monotonic() - start) * 1000)
        logger.info(json.dumps({
            "level": "INFO",
            "message": "get_restaurant_detail success",
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
            "body": json.dumps(item),
        }

    except Exception as exc:
        latency_ms = round((time.monotonic() - start) * 1000)
        logger.error(json.dumps({
            "level": "ERROR",
            "message": f"get_restaurant_detail error: {exc}",
            "route": ROUTE,
            "userSub": user_sub,
            "requestId": context.aws_request_id,
            "statusCode": 500,
            "latencyMs": latency_ms,
            "restaurantId": restaurant_id,
        }))
        return _error(500, "internal server error")
