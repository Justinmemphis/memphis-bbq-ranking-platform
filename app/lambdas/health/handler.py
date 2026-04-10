import json
import logging
import time

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """
    GET /v1/health
    Returns the caller's Cognito sub to verify the full auth chain:
    CloudFront → API Gateway JWT authorizer → Lambda.
    Security: requires a valid JWT; sub is read from authorizer context (not user input).
    """
    start = time.monotonic()

    request_context = event.get("requestContext", {})
    claims = (
        request_context
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
    )
    sub = claims.get("sub", "unauthenticated")
    latency_ms = round((time.monotonic() - start) * 1000)

    logger.info(json.dumps({
        "level": "INFO",
        "message": "health check",
        "route": "GET /v1/health",
        "userSub": sub,
        "requestId": request_context.get("requestId"),
        "statusCode": 200,
        "latencyMs": latency_ms,
    }))

    return {
        "statusCode": 200,
        "body": json.dumps({"status": "ok", "sub": sub}),
    }
