"""
Unit tests for app/lambdas/get_restaurant_detail/handler.py

Module-level boto3 binding: restaurants_table is patched via monkeypatch.
"""

import json

import lambdas.get_restaurant_detail.handler as detail_handler
from lambdas.get_restaurant_detail.handler import handler
from tests.conftest import make_event


def test_get_restaurant_detail_found(dynamodb_tables, monkeypatch):
    """Returns 200 with the restaurant item when it exists."""
    monkeypatch.setattr(detail_handler, "restaurants_table", dynamodb_tables["restaurants"])
    dynamodb_tables["restaurants"].put_item(Item={
        "restaurant_id": "paynes-bar-b-que",
        "name": "Payne's Bar-B-Que",
        "location": "Memphis, TN",
    })

    event = make_event(path_params={"restaurant_id": "paynes-bar-b-que"})
    response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["restaurant_id"] == "paynes-bar-b-que"
    assert body["name"] == "Payne's Bar-B-Que"


def test_get_restaurant_detail_not_found(dynamodb_tables, monkeypatch):
    """Returns 404 when the restaurant_id does not exist in the table."""
    monkeypatch.setattr(detail_handler, "restaurants_table", dynamodb_tables["restaurants"])

    event = make_event(path_params={"restaurant_id": "does-not-exist"})
    response = handler(event, {})
    assert response["statusCode"] == 404
    body = json.loads(response["body"])
    assert "not found" in body["message"].lower()


def test_get_restaurant_detail_missing_path_param(dynamodb_tables, monkeypatch):
    """Returns 400 when pathParameters is None."""
    monkeypatch.setattr(detail_handler, "restaurants_table", dynamodb_tables["restaurants"])

    event = make_event()  # pathParameters defaults to None
    response = handler(event, {})
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "restaurant_id" in body["message"].lower()


def test_get_restaurant_detail_blank_restaurant_id(dynamodb_tables, monkeypatch):
    """Returns 400 when restaurant_id is present but blank after strip()."""
    monkeypatch.setattr(detail_handler, "restaurants_table", dynamodb_tables["restaurants"])

    event = make_event(path_params={"restaurant_id": "   "})
    response = handler(event, {})
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "restaurant_id" in body["message"].lower()
