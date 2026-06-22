"""
PUT /v1/admin/restaurants/{restaurant_id}
Update mutable fields on an existing restaurant. Admin-only.

Design decisions:
- restaurant_id is immutable (it is the PK and referenced by all ratings).
  Attempts to include it in the request body are rejected with 400.
- created_at is also immutable — rejected if present in body.
- UpdateExpression is built dynamically from whichever mutable fields are
  present in the body. A request with no recognised fields returns 400.
- ExpressionAttributeNames are used for all field names to avoid DynamoDB
  reserved word collisions ('name' is reserved).
- ConditionExpression="attribute_exists(restaurant_id)" on UpdateItem prevents
  a silent upsert if the restaurant was deleted between the client's GetItem
  and this call. Maps ConditionalCheckFailedException to 404.
- updated_at is always appended server-side regardless of what the caller sends.

Security:
- JWT authorizer on the route (API Gateway layer).
- Server-side is_admin() check.
"""

import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

from shared.auth import get_user_sub, is_admin

logger = logging.getLogger()
logger.setLevel(logging.INFO)

COGNITO_USER_POOL_ID = os.environ["COGNITO_USER_POOL_ID"]
ROUTE = "PUT /v1/admin/restaurants/{restaurant_id}"

IMMUTABLE_FIELDS = {"restaurant_id", "created_at"}
MUTABLE_FIELDS = {"name", "address", "neighborhood", "style", "description", "phone", "website"}

# lat/lng stored as decimal strings; validated as real numbers before storage.
COORDINATE_FIELDS = {"lat", "lng"}

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

    restaurant_id = ((event.get("pathParameters") or {}).get("restaurant_id") or "").strip()
    if not restaurant_id:
        return _error(400, "restaurant_id path parameter is required")

    try:
        body = json.loads(event.get("body") or "{}")
    except (json.JSONDecodeError, TypeError):
        return _error(400, "invalid JSON body")

    immutable_in_body = IMMUTABLE_FIELDS & set(body.keys())
    if immutable_in_body:
        return _error(400, f"fields are immutable and cannot be updated: {sorted(immutable_in_body)}")

    update_fields = {}
    for field in MUTABLE_FIELDS:
        if field in body:
            val = str(body[field]).strip()
            if val:
                update_fields[field] = val

    for field in COORDINATE_FIELDS:
        if field in body:
            val = body[field]
            if val is not None and str(val).strip():
                try:
                    float(val)
                    update_fields[field] = str(val).strip()
                except (ValueError, TypeError):
                    return _error(400, f"'{field}' must be a valid decimal number (e.g. 35.1495)")

    all_updatable = sorted(MUTABLE_FIELDS | COORDINATE_FIELDS)
    if not update_fields:
        return _error(400, f"request must include at least one updatable field: {all_updatable}")

    update_fields["updated_at"] = datetime.now(timezone.utc).isoformat()

    set_parts = [f"#{k} = :{k}" for k in update_fields]
    update_expr = "SET " + ", ".join(set_parts)
    expr_attr_names = {f"#{k}": k for k in update_fields}
    expr_attr_values = {f":{k}": v for k, v in update_fields.items()}

    try:
        result = restaurants_table.update_item(
            Key={"restaurant_id": restaurant_id},
            UpdateExpression=update_expr,
            ExpressionAttributeNames=expr_attr_names,
            ExpressionAttributeValues=expr_attr_values,
            ConditionExpression="attribute_exists(restaurant_id)",
            ReturnValues="ALL_NEW",
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return _error(404, f"restaurant '{restaurant_id}' not found")
        latency_ms = round((time.monotonic() - start) * 1000)
        logger.error(json.dumps({
            "level": "ERROR",
            "message": f"admin_update_restaurant error: {e}",
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
            "message": f"admin_update_restaurant error: {exc}",
            "route": ROUTE,
            "userSub": user_sub,
            "requestId": request_id,
            "statusCode": 500,
            "latencyMs": latency_ms,
            "restaurantId": restaurant_id,
        }))
        return _error(500, "internal server error")

    updated_item = result.get("Attributes", {})
    latency_ms = round((time.monotonic() - start) * 1000)
    logger.info(json.dumps({
        "level": "INFO",
        "message": "admin_update_restaurant success",
        "route": ROUTE,
        "userSub": user_sub,
        "requestId": request_id,
        "statusCode": 200,
        "latencyMs": latency_ms,
        "restaurantId": restaurant_id,
    }))

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(updated_item),
    }
