import json
import logging
import os
import time
from decimal import Decimal

import boto3

from shared.auth import get_user_sub, is_admin

logger = logging.getLogger()
logger.setLevel(logging.INFO)

COGNITO_USER_POOL_ID = os.environ["COGNITO_USER_POOL_ID"]
RATING_EVENTS_TABLE = os.environ["RATING_EVENTS_TABLE"]

dynamodb = boto3.resource("dynamodb")


def _serialize(obj):
    """Convert Decimal (DynamoDB numeric type) to int/float for JSON serialization."""
    if isinstance(obj, Decimal):
        return int(obj) if obj % 1 == 0 else float(obj)
    raise TypeError(f"Object of type {type(obj)} is not JSON serializable")


def handler(event, context):
    """
    GET /v1/admin/audit-log?restaurant_id=<slug>

    Queries the rating_events table for all audit events for a given restaurant.
    Admin-only.

    Data model: rating_events PK = restaurant_id (slug), SK = created_at (ISO timestamp).
    A Query on PK is efficient regardless of item count — no table scan.

    Security: JWT validated by API Gateway. Admin group check is server-side.
    restaurant_id comes from a query string parameter — validated as non-empty,
    but no further sanitization is needed because DynamoDB Query uses exact key
    matching (not SQL interpolation) and the parameter cannot alter query logic.
    """
    start = time.monotonic()
    request_context = event.get("requestContext", {})
    sub = get_user_sub(event)
    route = "GET /v1/admin/audit-log"

    try:
        admin = is_admin(event, COGNITO_USER_POOL_ID)
    except Exception:
        logger.error(json.dumps({
            "level": "ERROR",
            "message": "cognito group lookup failed",
            "route": route,
            "userSub": sub,
            "requestId": request_context.get("requestId"),
            "statusCode": 500,
            "latencyMs": round((time.monotonic() - start) * 1000),
        }))
        return {"statusCode": 500, "body": json.dumps({"error": "internal server error"})}

    if not admin:
        logger.warning(json.dumps({
            "level": "WARNING",
            "message": "admin access denied",
            "route": route,
            "userSub": sub,
            "requestId": request_context.get("requestId"),
            "statusCode": 403,
            "latencyMs": round((time.monotonic() - start) * 1000),
        }))
        return {"statusCode": 403, "body": json.dumps({"error": "forbidden"})}

    restaurant_id = (event.get("queryStringParameters") or {}).get("restaurant_id", "").strip()
    if not restaurant_id:
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "restaurant_id query parameter is required"}),
        }

    table = dynamodb.Table(RATING_EVENTS_TABLE)
    response = table.query(
        KeyConditionExpression=boto3.dynamodb.conditions.Key("restaurant_id").eq(restaurant_id),
        # Newest events first — most useful for abuse investigation.
        ScanIndexForward=False,
        Limit=100,
    )

    # Intentional: items include user_id (Cognito sub) so admins can identify which
    # user submitted each rating during an abuse investigation. This is the authoritative
    # use case for this endpoint. No further projection needed — all stored fields are
    # appropriate for admin viewing (no PII beyond sub and score, which are operational).
    events = response.get("Items", [])
    latency_ms = round((time.monotonic() - start) * 1000)
    logger.info(json.dumps({
        "level": "INFO",
        "message": "admin audit log query",
        "route": route,
        "userSub": sub,
        "restaurantId": restaurant_id,
        "requestId": request_context.get("requestId"),
        "statusCode": 200,
        "latencyMs": latency_ms,
    }))
    return {
        "statusCode": 200,
        "body": json.dumps({"restaurant_id": restaurant_id, "events": events}, default=_serialize),
    }
