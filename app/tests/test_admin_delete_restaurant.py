"""Unit tests for app/lambdas/admin_delete_restaurant/handler.py"""

import json
from unittest.mock import MagicMock, patch

from botocore.exceptions import ClientError

import lambdas.admin_delete_restaurant.handler as delete_handler
import shared.leaderboard as leaderboard_module
from lambdas.admin_delete_restaurant.handler import handler
from tests.conftest import make_event

ADMIN_SUB = "admin-sub-delete-test"
RESTAURANT_ID = "paynes-bar-b-que"


def _admin_event(restaurant_id=RESTAURANT_ID):
    return make_event(
        sub=ADMIN_SUB,
        path_params={"restaurant_id": restaurant_id},
    )


def _patch_all_tables(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(delete_handler, "restaurants_table", dynamodb_tables["restaurants"])
    monkeypatch.setattr(delete_handler, "ratings_table", dynamodb_tables["ratings"])
    monkeypatch.setattr(delete_handler, "rating_events_table", dynamodb_tables["rating_events"])
    # recompute_leaderboard() lives in shared.leaderboard — patch its table refs.
    monkeypatch.setattr(leaderboard_module, "ratings_table", dynamodb_tables["ratings"])
    monkeypatch.setattr(leaderboard_module, "leaderboard_snapshot_table",
                        dynamodb_tables["leaderboard_snapshot"])


def _seed_restaurant(dynamodb_tables, restaurant_id=RESTAURANT_ID):
    dynamodb_tables["restaurants"].put_item(Item={
        "restaurant_id": restaurant_id,
        "name": "Payne's Bar-B-Que",
        "location": "Memphis, TN",
    })


def _seed_rating(dynamodb_tables, user_id, restaurant_id=RESTAURANT_ID, score=4):
    dynamodb_tables["ratings"].put_item(Item={
        "user_id": user_id,
        "restaurant_id": restaurant_id,
        "score": score,
    })


def _seed_rating_event(dynamodb_tables, restaurant_id=RESTAURANT_ID):
    dynamodb_tables["rating_events"].put_item(Item={
        "restaurant_id": restaurant_id,
        "created_at": "2026-01-01T00:00:00+00:00",
        "user_id": "some-user",
        "score": 4,
    })


def _seed_leaderboard(dynamodb_tables, restaurant_id=RESTAURANT_ID):
    dynamodb_tables["leaderboard_snapshot"].put_item(Item={
        "scope": "memphis#all",
        "rank": 1,
        "restaurant_id": restaurant_id,
        "bayesian_score": "3.5",
        "rating_count": 1,
    })


# ---------------------------------------------------------------------------
# Admin guard
# ---------------------------------------------------------------------------

def test_delete_non_admin(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(delete_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_all_tables(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_delete_restaurant.handler.is_admin", return_value=False):
        response = handler(_admin_event(), {})
    assert response["statusCode"] == 403


# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

def test_delete_missing_restaurant_id(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(delete_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_all_tables(monkeypatch, dynamodb_tables)
    event = make_event(sub=ADMIN_SUB, path_params={"restaurant_id": ""})
    with patch("lambdas.admin_delete_restaurant.handler.is_admin", return_value=True):
        response = handler(event, {})
    assert response["statusCode"] == 400
    assert "restaurant_id" in json.loads(response["body"])["message"].lower()


def test_delete_restaurant_not_found(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(delete_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_all_tables(monkeypatch, dynamodb_tables)
    with patch("lambdas.admin_delete_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event("ghost-restaurant"), {})
    assert response["statusCode"] == 404
    assert "not found" in json.loads(response["body"])["message"].lower()


# ---------------------------------------------------------------------------
# Happy path — cascade delete
# ---------------------------------------------------------------------------

def test_delete_success_cascade(monkeypatch, dynamodb_tables):
    """204 returned; restaurant, ratings, events, and leaderboard entry all removed."""
    monkeypatch.setattr(delete_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_all_tables(monkeypatch, dynamodb_tables)
    _seed_restaurant(dynamodb_tables)
    _seed_rating(dynamodb_tables, "user-1")
    _seed_rating(dynamodb_tables, "user-2")
    _seed_rating_event(dynamodb_tables)
    _seed_leaderboard(dynamodb_tables)

    with patch("lambdas.admin_delete_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event(), {})

    assert response["statusCode"] == 204

    # Restaurant deleted
    item = dynamodb_tables["restaurants"].get_item(Key={"restaurant_id": RESTAURANT_ID}).get("Item")
    assert item is None

    # Ratings deleted
    from boto3.dynamodb.conditions import Attr
    ratings = dynamodb_tables["ratings"].scan(
        FilterExpression=Attr("restaurant_id").eq(RESTAURANT_ID)
    )["Items"]
    assert ratings == []

    # Rating events deleted
    from boto3.dynamodb.conditions import Key
    events = dynamodb_tables["rating_events"].query(
        KeyConditionExpression=Key("restaurant_id").eq(RESTAURANT_ID)
    )["Items"]
    assert events == []

    # Leaderboard recomputed — no ratings remain so leaderboard is empty
    lb = dynamodb_tables["leaderboard_snapshot"].scan()["Items"]
    assert lb == []


def test_delete_no_ratings(monkeypatch, dynamodb_tables):
    """204 returned even when restaurant has no ratings or events (empty cascade)."""
    monkeypatch.setattr(delete_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_all_tables(monkeypatch, dynamodb_tables)
    _seed_restaurant(dynamodb_tables)

    with patch("lambdas.admin_delete_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event(), {})

    assert response["statusCode"] == 204
    item = dynamodb_tables["restaurants"].get_item(Key={"restaurant_id": RESTAURANT_ID}).get("Item")
    assert item is None


def test_delete_only_removes_target_restaurant_ratings(monkeypatch, dynamodb_tables):
    """Ratings for other restaurants are untouched by the cascade."""
    monkeypatch.setattr(delete_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _patch_all_tables(monkeypatch, dynamodb_tables)
    _seed_restaurant(dynamodb_tables, RESTAURANT_ID)
    _seed_restaurant(dynamodb_tables, "central-bbq")
    _seed_rating(dynamodb_tables, "user-1", RESTAURANT_ID)
    _seed_rating(dynamodb_tables, "user-1", "central-bbq", score=5)

    with patch("lambdas.admin_delete_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event(), {})

    assert response["statusCode"] == 204

    from boto3.dynamodb.conditions import Attr
    remaining = dynamodb_tables["ratings"].scan(
        FilterExpression=Attr("restaurant_id").eq("central-bbq")
    )["Items"]
    assert len(remaining) == 1


# ---------------------------------------------------------------------------
# Error path
# ---------------------------------------------------------------------------

def test_delete_dynamodb_error(monkeypatch, dynamodb_tables):
    monkeypatch.setattr(delete_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    _seed_restaurant(dynamodb_tables)
    mock_restaurants = MagicMock()
    mock_restaurants.get_item.return_value = {"Item": {"restaurant_id": RESTAURANT_ID}}
    mock_ratings = MagicMock()
    mock_ratings.scan.side_effect = ClientError(
        {"Error": {"Code": "InternalServerError", "Message": "simulated"}}, "Scan"
    )
    monkeypatch.setattr(delete_handler, "restaurants_table", mock_restaurants)
    monkeypatch.setattr(delete_handler, "ratings_table", mock_ratings)
    with patch("lambdas.admin_delete_restaurant.handler.is_admin", return_value=True):
        response = handler(_admin_event(), {})
    assert response["statusCode"] == 500
