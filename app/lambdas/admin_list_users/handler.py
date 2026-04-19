import json
import logging
import os
import time

import boto3

from shared.auth import get_user_sub, is_admin

logger = logging.getLogger()
logger.setLevel(logging.INFO)

COGNITO_USER_POOL_ID = os.environ["COGNITO_USER_POOL_ID"]


def handler(event, context):
    """
    GET /v1/admin/users

    Returns a list of users in the Cognito User Pool. Admin-only.

    Security: JWT validated by API Gateway. Group membership verified server-side
    via AdminListGroupsForUser — not via JWT claims — to ensure freshness.

    Returns at most 60 users per call (Cognito ListUsers limit is configurable;
    60 is the default page size). Pagination is not implemented for MVP — add
    a PaginationToken loop if the user base grows beyond one page.
    """
    start = time.monotonic()
    request_context = event.get("requestContext", {})
    sub = get_user_sub(event)
    route = "GET /v1/admin/users"

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

    client = boto3.client("cognito-idp")
    response = client.list_users(
        UserPoolId=COGNITO_USER_POOL_ID,
        Limit=60,
        # AttributesToGet limits the response payload and avoids leaking PII not
        # needed for the admin UI (only sub, email, and account status are shown).
        AttributesToGet=["sub", "email"],
    )

    users = []
    for u in response.get("Users", []):
        attrs = {a["Name"]: a["Value"] for a in u.get("Attributes", [])}
        users.append({
            "sub": attrs.get("sub", ""),
            "email": attrs.get("email", ""),
            "status": u.get("UserStatus", ""),
            "enabled": u.get("Enabled", True),
            "created": u.get("UserCreateDate", "").isoformat() if u.get("UserCreateDate") else "",
        })

    # Signal to the caller when results are truncated by the 60-user page limit.
    truncated = "PaginationToken" in response

    latency_ms = round((time.monotonic() - start) * 1000)
    logger.info(json.dumps({
        "level": "INFO",
        "message": "admin list users",
        "route": route,
        "userSub": sub,
        "requestId": request_context.get("requestId"),
        "statusCode": 200,
        "latencyMs": latency_ms,
    }))
    return {"statusCode": 200, "body": json.dumps({"users": users, "truncated": truncated})}
