import json
import logging

from shared.auth import get_user_sub

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """
    POST /v1/restaurants/{restaurant_id}/rating
    Creates or updates the caller's rating for a restaurant.
    One rating per user per restaurant — enforced by DynamoDB PK/SK (user_id, restaurant_id).
    Also writes an append-only entry to rating_events and updates leaderboard_snapshot.
    TODO: implement in Phase 2
    """
    logger.info(json.dumps({
        "level": "INFO",
        "message": "submit_rating invoked",
        "route": "POST /v1/restaurants/{restaurant_id}/rating",
        "userSub": get_user_sub(event),
        "requestId": context.aws_request_id,
    }))

    return {
        "statusCode": 501,
        "body": json.dumps({"message": "not implemented"}),
    }
