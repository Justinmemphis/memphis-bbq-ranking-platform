import json
import logging

from shared.auth import get_user_sub

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """
    GET /v1/restaurants/{restaurant_id}
    Returns restaurant details plus its current leaderboard score and vote count.
    TODO: implement in Phase 2
    """
    restaurant_id = event.get("pathParameters", {}).get("restaurant_id", "")

    logger.info(json.dumps({
        "level": "INFO",
        "message": "get_restaurant_detail invoked",
        "route": "GET /v1/restaurants/{restaurant_id}",
        "restaurantId": restaurant_id,
        "userSub": get_user_sub(event),
        "requestId": context.aws_request_id,
    }))

    return {
        "statusCode": 501,
        "body": json.dumps({"message": "not implemented"}),
    }
