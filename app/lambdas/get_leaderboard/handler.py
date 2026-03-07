import json
import logging

from shared.auth import get_user_sub

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """
    GET /v1/leaderboard?scope=memphis%23all&limit=50
    Reads from leaderboard_snapshot (never scans ratings directly).
    Response includes a `version` field to support future polling/push upgrades.
    TODO: implement in Phase 2
    """
    logger.info(json.dumps({
        "level": "INFO",
        "message": "get_leaderboard invoked",
        "route": "GET /v1/leaderboard",
        "userSub": get_user_sub(event),
        "requestId": context.aws_request_id,
    }))

    return {
        "statusCode": 501,
        "body": json.dumps({"message": "not implemented"}),
    }
