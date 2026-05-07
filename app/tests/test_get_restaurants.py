"""
Unit tests for app/lambdas/get_restaurants/handler.py

IMPORTANT — module-level boto3 binding:
get_restaurants/handler.py binds `table = dynamodb.Table(os.environ["RESTAURANTS_TABLE"])`
at import time.  We use monkeypatch to swap that module-level variable with the
moto-backed table created by the dynamodb_tables fixture so no real AWS call is made.
"""

import json
from unittest.mock import MagicMock

from botocore.exceptions import ClientError

import lambdas.get_restaurants.handler as get_restaurants_handler
from lambdas.get_restaurants.handler import handler
from tests.conftest import make_event


def test_get_restaurants_empty(dynamodb_tables, monkeypatch):
    """Empty table returns 200 with an empty list."""
    monkeypatch.setattr(get_restaurants_handler, "table", dynamodb_tables["restaurants"])
    event = make_event()
    response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["restaurants"] == []


def test_get_restaurants_two_items(dynamodb_tables, monkeypatch):
    """Two seeded items are returned."""
    monkeypatch.setattr(get_restaurants_handler, "table", dynamodb_tables["restaurants"])
    table = dynamodb_tables["restaurants"]
    table.put_item(Item={"restaurant_id": "paynes-bar-b-que", "name": "Payne's Bar-B-Que", "location": "Memphis, TN"})
    table.put_item(Item={"restaurant_id": "central-bbq", "name": "Central BBQ", "location": "Memphis, TN"})

    event = make_event()
    response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert len(body["restaurants"]) == 2


def test_get_restaurants_dynamodb_error(dynamodb_tables, monkeypatch):
    """A DynamoDB error is caught and returns 500."""
    monkeypatch.setattr(get_restaurants_handler, "table", dynamodb_tables["restaurants"])

    # Patch the scan method on the moto table object to raise ClientError
    error_response = {"Error": {"Code": "InternalServerError", "Message": "simulated"}}
    mock_table = MagicMock()
    mock_table.scan.side_effect = ClientError(error_response, "Scan")
    monkeypatch.setattr(get_restaurants_handler, "table", mock_table)

    event = make_event()
    response = handler(event, {})
    assert response["statusCode"] == 500
    body = json.loads(response["body"])
    assert "internal server error" in body["message"].lower()
