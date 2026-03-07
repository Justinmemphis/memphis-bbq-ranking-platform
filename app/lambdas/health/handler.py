import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """
    GET /v1/health
    Returns the caller's Cognito sub to verify the full auth chain:
    CloudFront → API Gateway JWT authorizer → Lambda.
    Security: requires a valid JWT; sub is read from authorizer context (not user input).
    """
    claims = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
    )
    sub = claims.get("sub", "unauthenticated")

    logger.info(json.dumps({
        "level": "INFO",
        "message": "health check",
        "route": "GET /v1/health",
        "userSub": sub,
        "requestId": context.aws_request_id,
    }))

    return {
        "statusCode": 200,
        "body": json.dumps({"status": "ok", "sub": sub}),
    }
