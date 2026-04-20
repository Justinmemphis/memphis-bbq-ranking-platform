import json
import logging
import os
import time

from shared.auth import get_user_sub, is_admin

logger = logging.getLogger()
logger.setLevel(logging.INFO)

COGNITO_USER_POOL_ID = os.environ["COGNITO_USER_POOL_ID"]


def handler(event, context):
    """
    GET /v1/admin/health

    Verifies the admin group guard pattern. Returns 200 for admin users, 403 for
    all others. Serves as a smoke-test endpoint during Sprint 23 development and
    as a liveness check for the admin subsystem.

    Security: JWT validation is handled upstream by API Gateway. This function
    performs a server-side Cognito group check (not a JWT claim check) to confirm
    admin membership — authoritative at request time, not at token-issuance time.
    """
    start = time.monotonic()
    request_context = event.get("requestContext", {})
    sub = get_user_sub(event)
    route = "GET /v1/admin/health"

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
            "message": "admin access denied — caller not in admin group",
            "route": route,
            "userSub": sub,
            "requestId": request_context.get("requestId"),
            "statusCode": 403,
            "latencyMs": round((time.monotonic() - start) * 1000),
        }))
        return {"statusCode": 403, "body": json.dumps({"error": "forbidden"})}

    latency_ms = round((time.monotonic() - start) * 1000)
    logger.info(json.dumps({
        "level": "INFO",
        "message": "admin health check",
        "route": route,
        "userSub": sub,
        "requestId": request_context.get("requestId"),
        "statusCode": 200,
        "latencyMs": latency_ms,
    }))
    return {"statusCode": 200, "body": json.dumps({"status": "ok", "admin": True})}
