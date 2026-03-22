import json
import logging
import os
import time

import boto3

from shared.auth import get_user_sub

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Module-level client — reused across warm invocations (avoids re-initializing on every call).
# Table name injected via environment variable so the same code works in dev and prod.
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["RESTAURANTS_TABLE"])


def handler(event, context):
    """
    GET /v1/restaurants
    Returns all restaurants as a JSON array.

    Uses a DynamoDB Scan — acceptable for a small, bounded dataset (Memphis BBQ joints).
    If the dataset grows significantly, this should be replaced with a paginated Query
    against a GSI or a dedicated search index.

    Security: caller identity (sub) is logged but not used to filter results —
    the restaurant list is the same for all authenticated users.
    """
    start = time.monotonic()
    user_sub = get_user_sub(event)

    try:
        # Scan with automatic pagination.
        # DynamoDB returns up to 1 MB per call; LastEvaluatedKey signals more pages.
        # For a small dataset this loop runs once, but correct from day one.
        response = table.scan()
        restaurants = response.get("Items", [])
        while "LastEvaluatedKey" in response:
            response = table.scan(ExclusiveStartKey=response["LastEvaluatedKey"])
            restaurants.extend(response.get("Items", []))

        latency_ms = round((time.monotonic() - start) * 1000)

        logger.info(json.dumps({
            "level": "INFO",
            "message": "get_restaurants success",
            "route": "GET /v1/restaurants",
            "userSub": user_sub,
            "requestId": context.aws_request_id,
            "statusCode": 200,
            "latencyMs": latency_ms,
            "resultCount": len(restaurants),
        }))

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"restaurants": restaurants}),
        }

    except Exception as exc:
        latency_ms = round((time.monotonic() - start) * 1000)
        logger.error(json.dumps({
            "level": "ERROR",
            "message": f"get_restaurants error: {exc}",
            "route": "GET /v1/restaurants",
            "userSub": user_sub,
            "requestId": context.aws_request_id,
            "statusCode": 500,
            "latencyMs": latency_ms,
        }))
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"message": "internal server error"}),
        }
