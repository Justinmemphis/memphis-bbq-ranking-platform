"""
Unit tests for app/lambdas/submit_rating/handler.py

Module-level boto3 binding: submit_rating binds four tables at import time.
All four are patched via monkeypatch.

The handler also calls _recompute_leaderboard() which scans ratings and writes
to leaderboard_snapshot — both are covered by the moto-backed tables.
"""

import json
from unittest.mock import MagicMock

from botocore.exceptions import ClientError

import lambdas.submit_rating.handler as submit_handler
import shared.leaderboard as leaderboard_module
from lambdas.submit_rating.handler import handler
from tests.conftest import make_event


def _patch_all_tables(monkeypatch, dynamodb_tables):
    """Patch all module-level table objects in submit_rating and shared.leaderboard."""
    monkeypatch.setattr(submit_handler, "restaurants_table", dynamodb_tables["restaurants"])
    monkeypatch.setattr(submit_handler, "ratings_table", dynamodb_tables["ratings"])
    monkeypatch.setattr(submit_handler, "rating_events_table", dynamodb_tables["rating_events"])
    # recompute_leaderboard() now lives in shared.leaderboard — patch its table refs too.
    monkeypatch.setattr(leaderboard_module, "ratings_table", dynamodb_tables["ratings"])
    monkeypatch.setattr(leaderboard_module, "leaderboard_snapshot_table",
                        dynamodb_tables["leaderboard_snapshot"])


def _seed_restaurant(dynamodb_tables, restaurant_id="paynes-bar-b-que"):
    dynamodb_tables["restaurants"].put_item(Item={
        "restaurant_id": restaurant_id,
        "name": "Payne's Bar-B-Que",
        "location": "Memphis, TN",
    })


# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

def test_submit_rating_missing_restaurant_id(dynamodb_tables, monkeypatch):
    """Missing restaurant_id in body returns 400."""
    _patch_all_tables(monkeypatch, dynamodb_tables)
    event = make_event(body=json.dumps({"score": 5}))
    response = handler(event, {})
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "restaurant_id" in body["message"].lower()


def test_submit_rating_score_zero(dynamodb_tables, monkeypatch):
    """score=0 is out of range [1,5] — returns 400."""
    _patch_all_tables(monkeypatch, dynamodb_tables)
    _seed_restaurant(dynamodb_tables)
    event = make_event(body=json.dumps({"restaurant_id": "paynes-bar-b-que", "score": 0}))
    response = handler(event, {})
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "score" in body["message"].lower()


def test_submit_rating_score_six(dynamodb_tables, monkeypatch):
    """score=6 is out of range [1,5] — returns 400."""
    _patch_all_tables(monkeypatch, dynamodb_tables)
    _seed_restaurant(dynamodb_tables)
    event = make_event(body=json.dumps({"restaurant_id": "paynes-bar-b-que", "score": 6}))
    response = handler(event, {})
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "score" in body["message"].lower()


# ---------------------------------------------------------------------------
# Restaurant existence check
# ---------------------------------------------------------------------------

def test_submit_rating_restaurant_not_found(dynamodb_tables, monkeypatch):
    """Rating for a non-existent restaurant returns 404."""
    _patch_all_tables(monkeypatch, dynamodb_tables)
    event = make_event(body=json.dumps({"restaurant_id": "ghost-restaurant", "score": 4}))
    response = handler(event, {})
    assert response["statusCode"] == 404
    body = json.loads(response["body"])
    assert "not found" in body["message"].lower()


# ---------------------------------------------------------------------------
# Happy-path writes
# ---------------------------------------------------------------------------

def test_submit_rating_new_rating(dynamodb_tables, monkeypatch):
    """
    A valid new rating:
      - Returns 200
      - Writes item to ratings table
      - Writes event to rating_events table
      - Updates leaderboard_snapshot
    """
    _patch_all_tables(monkeypatch, dynamodb_tables)
    _seed_restaurant(dynamodb_tables)

    event = make_event(sub="user-sub-1", body=json.dumps({"restaurant_id": "paynes-bar-b-que", "score": 5}))
    response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["message"] == "rating submitted"
    assert body["score"] == 5

    # Rating was written to the ratings table
    rating_item = dynamodb_tables["ratings"].get_item(
        Key={"user_id": "user-sub-1", "restaurant_id": "paynes-bar-b-que"}
    ).get("Item")
    assert rating_item is not None
    assert int(rating_item["score"]) == 5

    # Audit event was written
    events_resp = dynamodb_tables["rating_events"].query(
        KeyConditionExpression=boto3_key("restaurant_id").eq("paynes-bar-b-que")
    )
    assert len(events_resp["Items"]) >= 1

    # Leaderboard was updated
    lb_resp = dynamodb_tables["leaderboard_snapshot"].query(
        KeyConditionExpression=boto3_key("scope").eq("memphis#all")
    )
    assert len(lb_resp["Items"]) >= 1


def test_submit_rating_upsert(dynamodb_tables, monkeypatch):
    """
    Submitting a second rating for the same user+restaurant is an upsert,
    not a duplicate — only one item exists in the ratings table after two calls.
    """
    _patch_all_tables(monkeypatch, dynamodb_tables)
    _seed_restaurant(dynamodb_tables)

    event1 = make_event(sub="user-sub-upsert",
                        body=json.dumps({"restaurant_id": "paynes-bar-b-que", "score": 3}))
    event2 = make_event(sub="user-sub-upsert",
                        body=json.dumps({"restaurant_id": "paynes-bar-b-que", "score": 5}))

    r1 = handler(event1, {})
    r2 = handler(event2, {})
    assert r1["statusCode"] == 200
    assert r2["statusCode"] == 200

    # Scan the ratings table: only one item for this user+restaurant
    resp = dynamodb_tables["ratings"].scan()
    user_restaurant_items = [
        i for i in resp["Items"]
        if i["user_id"] == "user-sub-upsert" and i["restaurant_id"] == "paynes-bar-b-que"
    ]
    assert len(user_restaurant_items) == 1
    # Score was updated to the latest value
    assert int(user_restaurant_items[0]["score"]) == 5


# ---------------------------------------------------------------------------
# Error path
# ---------------------------------------------------------------------------

def test_submit_rating_dynamodb_error_on_put(dynamodb_tables, monkeypatch):
    """A DynamoDB error during ratings put_item returns 500."""
    _patch_all_tables(monkeypatch, dynamodb_tables)
    _seed_restaurant(dynamodb_tables)

    error_response = {"Error": {"Code": "InternalServerError", "Message": "simulated"}}
    mock_ratings = MagicMock()
    mock_ratings.put_item.side_effect = ClientError(error_response, "PutItem")
    monkeypatch.setattr(submit_handler, "ratings_table", mock_ratings)

    event = make_event(sub="user-sub-err",
                       body=json.dumps({"restaurant_id": "paynes-bar-b-que", "score": 4}))
    response = handler(event, {})
    assert response["statusCode"] == 500
    body = json.loads(response["body"])
    assert "internal server error" in body["message"].lower()


# ---------------------------------------------------------------------------
# Helper — import Key condition after sys.path is configured by conftest
# ---------------------------------------------------------------------------

def boto3_key(attr):
    from boto3.dynamodb.conditions import Key
    return Key(attr)
