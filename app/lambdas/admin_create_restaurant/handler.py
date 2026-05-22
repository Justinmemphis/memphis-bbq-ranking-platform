"""
POST /v1/admin/restaurants
Create a new restaurant record. Admin-only.

Design decisions:
- restaurant_id is caller-supplied as a slug (e.g. "paynes-bar-b-que"). It is
  the DynamoDB PK and is immutable after creation — all ratings and leaderboard
  entries reference it. Callers own the slug so they can choose a stable,
  human-readable identifier without a separate ID generation step.
- ConditionExpression="attribute_not_exists(restaurant_id)" on PutItem makes
  create atomic: if a record already exists the call fails with
  ConditionalCheckFailedException, which maps to 409. No separate GetItem needed.
- created_at and updated_at are set server-side (not from the request body)
  so clocks are authoritative and callers cannot forge timestamps.

Security:
- JWT authorizer on the route (API Gateway layer).
- Server-side is_admin() check via AdminListGroupsForUser (authoritative — JWT
  claim alone is insufficient because groups are not in the access token by default
  and may be stale).
- restaurant_id slug validation rejects injection attempts and path-traversal
  characters before the DynamoDB write.
"""

import json
import logging
import os
import re
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

from shared.auth import get_user_sub, is_admin

logger = logging.getLogger()
logger.setLevel(logging.INFO)

COGNITO_USER_POOL_ID = os.environ["COGNITO_USER_POOL_ID"]
ROUTE = "POST /v1/admin/restaurants"

# Lowercase alphanumeric + hyphens, no leading/trailing hyphens, min 3 chars.
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9\-]+[a-z0-9]$")

MUTABLE_FIELDS = {"address", "neighborhood", "style", "description"}

dynamodb = boto3.resource("dynamodb")
restaurants_table = dynamodb.Table(os.environ["RESTAURANTS_TABLE"])


def _error(status_code, message):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"message": message}),
    }


def handler(event, context):
    start = time.monotonic()
    user_sub = get_user_sub(event)
    request_id = event.get("requestContext", {}).get("requestId")

    if not is_admin(event, COGNITO_USER_POOL_ID):
        return _error(403, "admin access required")

    try:
        body = json.loads(event.get("body") or "{}")
    except (json.JSONDecodeError, TypeError):
        return _error(400, "invalid JSON body")

    restaurant_id = str(body.get("restaurant_id", "")).strip()
    if not restaurant_id:
        return _error(400, "restaurant_id is required")
    if not SLUG_RE.match(restaurant_id):
        return _error(
            400,
            "restaurant_id must be lowercase alphanumeric and hyphens (e.g. paynes-bar-b-que), minimum 3 characters",
        )

    name = str(body.get("name", "")).strip()
    if not name:
        return _error(400, "name is required")

    now = datetime.now(timezone.utc).isoformat()
    item = {
        "restaurant_id": restaurant_id,
        "name": name,
        "created_at": now,
        "updated_at": now,
    }
    for field in MUTABLE_FIELDS:
        val = str(body.get(field, "")).strip()
        if val:
            item[field] = val

    try:
        restaurants_table.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(restaurant_id)",
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return _error(409, f"restaurant '{restaurant_id}' already exists")
        latency_ms = round((time.monotonic() - start) * 1000)
        logger.error(json.dumps({
            "level": "ERROR",
            "message": f"admin_create_restaurant error: {e}",
            "route": ROUTE,
            "userSub": user_sub,
            "requestId": request_id,
            "statusCode": 500,
            "latencyMs": latency_ms,
            "restaurantId": restaurant_id,
        }))
        return _error(500, "internal server error")
    except Exception as exc:
        latency_ms = round((time.monotonic() - start) * 1000)
        logger.error(json.dumps({
            "level": "ERROR",
            "message": f"admin_create_restaurant error: {exc}",
            "route": ROUTE,
            "userSub": user_sub,
            "requestId": request_id,
            "statusCode": 500,
            "latencyMs": latency_ms,
            "restaurantId": restaurant_id,
        }))
        return _error(500, "internal server error")

    latency_ms = round((time.monotonic() - start) * 1000)
    logger.info(json.dumps({
        "level": "INFO",
        "message": "admin_create_restaurant success",
        "route": ROUTE,
        "userSub": user_sub,
        "requestId": request_id,
        "statusCode": 201,
        "latencyMs": latency_ms,
        "restaurantId": restaurant_id,
    }))

    return {
        "statusCode": 201,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(item),
    }
