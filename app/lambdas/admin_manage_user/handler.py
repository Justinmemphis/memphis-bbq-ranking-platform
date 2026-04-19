import json
import logging
import os
import time

import boto3
from botocore.exceptions import ClientError

from shared.auth import get_user_sub, is_admin

logger = logging.getLogger()
logger.setLevel(logging.INFO)

COGNITO_USER_POOL_ID = os.environ["COGNITO_USER_POOL_ID"]

ALLOWED_ACTIONS = {"disable", "enable", "force_reset"}


def handler(event, context):
    """
    POST /v1/admin/users/{sub}/action

    Performs an admin action on a Cognito user. Admin-only.
    Body: {"action": "disable" | "enable" | "force_reset"}

    Security:
    - JWT validated by API Gateway before invocation.
    - Admin group membership verified server-side (not via JWT claim).
    - target_sub comes from the URL path parameter (not caller's own sub).
    - Actions are enumerated — no arbitrary API calls possible.
    - An admin cannot disable themselves via this endpoint (returns 400) to
      prevent accidental lockout. A second admin would need to re-enable them.
    """
    start = time.monotonic()
    request_context = event.get("requestContext", {})
    caller_sub = get_user_sub(event)
    route = "POST /v1/admin/users/{sub}/action"
    target_sub = (event.get("pathParameters") or {}).get("sub", "")

    def log_and_return(status_code, message, body, level="INFO"):
        log_fn = logger.info if level == "INFO" else (logger.warning if level == "WARNING" else logger.error)
        log_fn(json.dumps({
            "level": level,
            "message": message,
            "route": route,
            "userSub": caller_sub,
            "requestId": request_context.get("requestId"),
            "statusCode": status_code,
            "latencyMs": round((time.monotonic() - start) * 1000),
        }))
        return {"statusCode": status_code, "body": json.dumps(body)}

    try:
        admin = is_admin(event, COGNITO_USER_POOL_ID)
    except Exception:
        return log_and_return(500, "cognito group lookup failed", {"error": "internal server error"}, "ERROR")

    if not admin:
        return log_and_return(403, "admin access denied", {"error": "forbidden"}, "WARNING")

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return log_and_return(400, "invalid request body", {"error": "body must be valid JSON"})

    action = body.get("action", "")
    if action not in ALLOWED_ACTIONS:
        return log_and_return(400, "invalid action", {"error": f"action must be one of: {', '.join(sorted(ALLOWED_ACTIONS))}"})

    if not target_sub:
        return log_and_return(400, "missing target sub", {"error": "sub path parameter required"})

    # Prevent an admin from accidentally locking themselves out.
    # force_reset is also blocked: it would invalidate the caller's own sessions.
    if action in {"disable", "force_reset"} and target_sub == caller_sub:
        return log_and_return(400, "self-action not allowed", {"error": f"cannot {action} your own account"})

    client = boto3.client("cognito-idp")
    try:
        if action == "disable":
            client.admin_disable_user(UserPoolId=COGNITO_USER_POOL_ID, Username=target_sub)
        elif action == "enable":
            client.admin_enable_user(UserPoolId=COGNITO_USER_POOL_ID, Username=target_sub)
        elif action == "force_reset":
            client.admin_reset_user_password(UserPoolId=COGNITO_USER_POOL_ID, Username=target_sub)
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code == "UserNotFoundException":
            return log_and_return(404, "user not found", {"error": "user not found"})
        logger.error(json.dumps({
            "level": "ERROR",
            "message": f"cognito action failed: {code}",
            "route": route,
            "userSub": caller_sub,
            "requestId": request_context.get("requestId"),
            "statusCode": 500,
            "latencyMs": round((time.monotonic() - start) * 1000),
        }))
        return {"statusCode": 500, "body": json.dumps({"error": "internal server error"})}

    return log_and_return(200, f"admin action completed: {action}", {"action": action, "sub": target_sub})
