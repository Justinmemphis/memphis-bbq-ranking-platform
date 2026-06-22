"""Unit tests for app/lambdas/admin_create_restaurant/handler.py"""

import json
from unittest.mock import MagicMock, patch

from botocore.exceptions import ClientError

import lambdas.admin_create_restaurant.handler as create_handler
from lambdas.admin_create_restaurant.handler import handler
from tests.conftest import make_event

ADMIN_SUB = "admin-sub-create-test"


def _admin_event(body=None, restaurant_id=None):
    return make_event(
        sub=ADMIN_SUB,
        body=json.dumps(body or {}),
        path_params={"restaurant_id": restaurant_id} if restaurant_id else None,
    )


def _patch_table(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(create_handler, "restaurants_table", dynamodb_tables["restaurants"])


# ---------------------------------------------------------------------------
# Admin guard
# ---------------------------------------------------------------------------

def test_create_non_admin(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(create_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_create_restaurant.handler.is_admin", return_value=False):
        response = handler(_admin_event({"restaurant_id": "test-bbq", "name": "Test BBQ"}), {})
    assert response["statusCode"] == 403


# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

def test_create_invalid_json(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(create_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    event = make_event(sub=ADMIN_SUB, body="not-json{{{")
    with patch("lambdas.admin_create_restaurant.handler.is_admin", return_value=True):
        response = handler(event, {})
    assert response["statusCode"] == 400
    assert "json" in json.loads(response["body"])["message"].lower()


def test_create_missing_restaurant_id(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(create_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_create_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event({"name": "Test BBQ"}), {})
    assert response["statusCode"] == 400
    assert "restaurant_id" in json.loads(response["body"])["message"].lower()


def test_create_invalid_slug_uppercase(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(create_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_create_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event({"restaurant_id": "Test-BBQ", "name": "Test BBQ"}), {})
    assert response["statusCode"] == 400


def test_create_invalid_slug_too_short(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(create_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_create_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event({"restaurant_id": "ab", "name": "Test BBQ"}), {})
    assert response["statusCode"] == 400


def test_create_invalid_slug_leading_hyphen(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(create_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_create_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event({"restaurant_id": "-test-bbq", "name": "Test BBQ"}), {})
    assert response["statusCode"] == 400


def test_create_missing_name(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(create_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_create_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event({"restaurant_id": "test-bbq"}), {})
    assert response["statusCode"] == 400
    assert "name" in json.loads(response["body"])["message"].lower()


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

def test_create_success(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(create_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_create_restaurant.handler.is_admin", return_value=True):
        response = handler(
            _admin_event({"restaurant_id": "new-bbq-spot", "name": "New BBQ Spot", "address": "123 Main St"}),
            {},
        )
    assert response["statusCode"] == 201
    body = json.loads(response["body"])
    assert body["restaurant_id"] == "new-bbq-spot"
    assert body["name"] == "New BBQ Spot"
    assert body["address"] == "123 Main St"
    assert "created_at" in body
    assert "updated_at" in body

    item = dynamodb_tables["restaurants"].get_item(Key={"restaurant_id": "new-bbq-spot"}).get("Item")
    assert item is not None
    assert item["name"] == "New BBQ Spot"


def test_create_with_all_fields(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(create_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_create_restaurant.handler.is_admin", return_value=True):
        response = handler(
            _admin_event({
                "restaurant_id": "full-bbq",
                "name": "Full BBQ",
                "address": "456 Beale St",
                "neighborhood": "Downtown",
                "phone": "901-555-0100",
                "website": "https://fullbbq.com",
                "style": "dry rub",
                "description": "Famous for ribs.",
                "lat": "35.1495",
                "lng": "-90.0490",
            }),
            {},
        )
    assert response["statusCode"] == 201
    body = json.loads(response["body"])
    assert body["phone"] == "901-555-0100"
    assert body["website"] == "https://fullbbq.com"
    assert body["lat"] == "35.1495"
    assert body["lng"] == "-90.0490"


def test_create_invalid_lat(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(create_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_create_restaurant.handler.is_admin", return_value=True):
        response = handler(
            _admin_event({"restaurant_id": "bad-coords", "name": "X", "lat": "not-a-number"}),
            {},
        )
    assert response["statusCode"] == 400
    assert "lat" in json.loads(response["body"])["message"].lower()


def test_create_duplicate(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(create_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_table(monkeypatch, dynamodb_tables)
    dynamodb_tables["restaurants"].put_item(Item={"restaurant_id": "existing-bbq", "name": "Existing"})
    with patch("lambdas.admin_create_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event({"restaurant_id": "existing-bbq", "name": "New Name"}), {})
    assert response["statusCode"] == 409
    assert "already exists" in json.loads(response["body"])["message"].lower()


# ---------------------------------------------------------------------------
# Error path
# ---------------------------------------------------------------------------

def test_create_dynamodb_error(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(create_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    mock_table = MagicMock()
    mock_table.put_item.side_effect = ClientError(
        {"Error": {"Code": "InternalServerError", "Message": "simulated"}}, "PutItem"
    )
    monkeypatch.setattr(create_handler, "restaurants_table", mock_table)
    with patch("lambdas.admin_create_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event({"restaurant_id": "error-bbq", "name": "Error BBQ"}), {})
    assert response["statusCode"] == 500
