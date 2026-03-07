import json
import logging

from shared.auth import get_user_sub

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """
    GET /v1/restaurants
    Returns list of restaurants. Supports optional query params for filtering.
    TODO: implement in Phase 2
    """
    logger.info(json.dumps({
        "level": "INFO",
        "message": "get_restaurants invoked",
        "route": "GET /v1/restaurants",
        "userSub": get_user_sub(event),
        "requestId": context.aws_request_id,
    }))

    return {
        "statusCode": 501,
        "body": json.dumps({"message": "not implemented"}),
    }
