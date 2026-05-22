"""Unit tests for app/lambdas/admin_update_restaurant/handler.py"""

import json
from unittest.mock import MagicMock, patch

from botocore.exceptions import ClientError

import lambdas.admin_update_restaurant.handler as update_handler
from lambdas.admin_update_restaurant.handler import handler
from tests.conftest import make_event

ADMIN_SUB = "admin-sub-update-test"
RESTAURANT_ID = "paynes-bar-b-que"


def _admin_event(body, restaurant_id=RESTAURANT_ID):
    return make_event(
        sub=ADMIN_SUB,
        path_params={"restaurant_id": restaurant_id},
        body=json.dumps(body),
    )


def _seed(dynamodb_tables, restaurant_id=RESTAURANT_ID):
    dynamodb_tables["restaurants"].put_item(Item={
        "restaurant_id": restaurant_id,
        "name": "Payne's Bar-B-Que",
        "location": "Memphis, TN",
        "created_at": "2026-01-01T00:00:00+00:00",
    })


def _patch_table(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(update_handler, "restaurants_table", dynamodb_tables["restaurants"])


# ---------------------------------------------------------------------------
# Admin guard
# ---------------------------------------------------------------------------

def test_update_non_admin(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(update_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_update_restaurant.handler.is_admin", return_value=False):
        response = handler(_admin_event({"name": "New Name"}), {})
    assert response["statusCode"] == 403


# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

def test_update_immutable_field_restaurant_id(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(update_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_update_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event({"restaurant_id": "new-id", "name": "X"}), {})
    assert response["statusCode"] == 400
    assert "immutable" in json.loads(response["body"])["message"].lower()


def test_update_immutable_field_created_at(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(update_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_update_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event({"created_at": "2020-01-01", "name": "X"}), {})
    assert response["statusCode"] == 400
    assert "immutable" in json.loads(response["body"])["message"].lower()


def test_update_no_mutable_fields(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(update_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_update_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event({"unknown_field": "value"}), {})
    assert response["statusCode"] == 400
    assert "updatable" in json.loads(response["body"])["message"].lower()


def test_update_restaurant_not_found(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(update_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_update_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event({"name": "New Name"}, restaurant_id="ghost-restaurant"), {})
    assert response["statusCode"] == 404
    assert "not found" in json.loads(response["body"])["message"].lower()


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

def test_update_success(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(update_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    _seed(dynamodb_tables)
    with patch("lambdas.admin_update_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event({"name": "Payne's Updated", "address": "901 Main St"}), {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["name"] == "Payne's Updated"
    assert body["address"] == "901 Main St"
    assert "updated_at" in body

    item = dynamodb_tables["restaurants"].get_item(Key={"restaurant_id": RESTAURANT_ID}).get("Item")
    assert item["name"] == "Payne's Updated"


def test_update_updated_at_changes(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(update_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    _seed(dynamodb_tables)
    with patch("lambdas.admin_update_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event({"name": "Updated Name"}), {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body.get("updated_at", "") != "2026-01-01T00:00:00+00:00"


# ---------------------------------------------------------------------------
# Error path
# ---------------------------------------------------------------------------

def test_update_dynamodb_error(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(update_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    mock_table = MagicMock()
    mock_table.update_item.side_effect = ClientError(
        {"Error": {"Code": "InternalServerError", "Message": "simulated"}}, "UpdateItem"
    )
    monkeypatch.setattr(update_handler, "restaurants_table", mock_table)
    with patch("lambdas.admin_update_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event({"name": "New Name"}), {})
    assert response["statusCode"] == 500
