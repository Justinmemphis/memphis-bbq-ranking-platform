"""
DELETE /v1/admin/restaurants/{restaurant_id}
Hard-delete a restaurant and cascade-delete all associated data. Admin-only.

Cascade order (sequence matters):
1. Delete all ratings for this restaurant (Scan ratings table — no GSI on
   restaurant_id; same limitation acknowledged in submit_rating/handler.py).
2. Delete all rating_events for this restaurant (Query by PK — efficient).
3. Delete the restaurant record itself.
4. Recompute the leaderboard — with ratings gone, the restaurant will naturally
   disappear from the snapshot.

Design decisions:
- Hard delete, no soft-delete or recycle bin. Appropriate for a demo/portfolio
  app with a small, admin-controlled dataset. The leaderboard recompute after
  ratings deletion produces a correct result in one pass.
- GetItem before DeleteItem returns a clean 404 for unknown restaurant_id values
  rather than silently succeeding. This guards against accidental deletions of
  IDs that were never created.
- 204 No Content response — standard for a successful DELETE with no body.

Security:
- JWT authorizer on the route (API Gateway layer).
- Server-side is_admin() check — authoritative even if JWT group claims are stale.
- IAM role scoped to specific table ARNs; no Resource: "*".

IAM flag: this handler has the widest DynamoDB scope in the project — it needs
Scan + DeleteItem on ratings, Query + DeleteItem on rating_events, and full
leaderboard write permissions. Each statement is scoped to a specific table ARN.
"""

import json
import logging
import os
import time

import boto3
from boto3.dynamodb.conditions import Attr, Key

from shared.auth import get_user_sub, is_admin
from shared.leaderboard import recompute_leaderboard

logger = logging.getLogger()
logger.setLevel(logging.INFO)

COGNITO_USER_POOL_ID = os.environ["COGNITO_USER_POOL_ID"]
ROUTE = "DELETE /v1/admin/restaurants/{restaurant_id}"

dynamodb = boto3.resource("dynamodb")
restaurants_table = dynamodb.Table(os.environ["RESTAURANTS_TABLE"])
ratings_table = dynamodb.Table(os.environ["RATINGS_TABLE"])
rating_events_table = dynamodb.Table(os.environ["RATING_EVENTS_TABLE"])


def _error(status_code, message):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"message": message}),
    }


def _delete_ratings(restaurant_id):
    """
    Scan-and-delete all ratings for restaurant_id.
    Scan is required because ratings table has no GSI on restaurant_id.
    Paginated to handle datasets larger than the 1 MB DynamoDB scan limit.
    """
    paginator_kwargs = {}
    while True:
        response = ratings_table.scan(
            FilterExpression=Attr("restaurant_id").eq(restaurant_id),
            ProjectionExpression="user_id, restaurant_id",
            **paginator_kwargs,
        )
        for item in response.get("Items", []):
            ratings_table.delete_item(
                Key={"user_id": item["user_id"], "restaurant_id": item["restaurant_id"]},
            )
        last_key = response.get("LastEvaluatedKey")
        if not last_key:
            break
        paginator_kwargs["ExclusiveStartKey"] = last_key


def _delete_rating_events(restaurant_id):
    """
    Query-and-delete all rating_events for restaurant_id.
    Query on PK is efficient — no scan needed.
    """
    paginator_kwargs = {}
    while True:
        response = rating_events_table.query(
            KeyConditionExpression=Key("restaurant_id").eq(restaurant_id),
            ProjectionExpression="restaurant_id, created_at",
            **paginator_kwargs,
        )
        for item in response.get("Items", []):
            rating_events_table.delete_item(
                Key={"restaurant_id": item["restaurant_id"], "created_at": item["created_at"]},
            )
        last_key = response.get("LastEvaluatedKey")
        if not last_key:
            break
        paginator_kwargs["ExclusiveStartKey"] = last_key


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
        existing = restaurants_table.get_item(
            Key={"restaurant_id": restaurant_id},
            ProjectionExpression="restaurant_id",
        )
        if "Item" not in existing:
            return _error(404, f"restaurant '{restaurant_id}' not found")

        _delete_ratings(restaurant_id)
        _delete_rating_events(restaurant_id)

        restaurants_table.delete_item(Key={"restaurant_id": restaurant_id})

        recompute_leaderboard()

    except Exception as exc:
        latency_ms = round((time.monotonic() - start) * 1000)
        logger.error(json.dumps({
            "level": "ERROR",
            "message": f"admin_delete_restaurant error: {exc}",
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
        "message": "admin_delete_restaurant success",
        "route": ROUTE,
        "userSub": user_sub,
        "requestId": request_id,
        "statusCode": 204,
        "latencyMs": latency_ms,
        "restaurantId": restaurant_id,
    }))

    return {
        "statusCode": 204,
        "headers": {"Content-Type": "application/json"},
        "body": "",
    }
