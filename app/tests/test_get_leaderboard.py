"""
Unit tests for app/lambdas/get_leaderboard/handler.py

Module-level boto3 binding: leaderboard_snapshot_table is patched via monkeypatch.

Leaderboard items use:
  PK: scope (S)  SK: rank (N)
Additional fields expected by handler: bayesian_score, rating_count, algorithm_version
"""

import json
from decimal import Decimal

import lambdas.get_leaderboard.handler as leaderboard_handler
from lambdas.get_leaderboard.handler import handler
from tests.conftest import make_event


def _seed_leaderboard(table, count, scope="memphis#all"):
    """Helper: insert `count` leaderboard items into the moto table."""
    for i in range(1, count + 1):
        table.put_item(Item={
            "scope": scope,
            "rank": i,
            "restaurant_id": f"restaurant-{i}",
            "bayesian_score": Decimal("4.0"),
            "rating_count": 10,
            "algorithm_version": "bayesian-v1",
            "version": "2025-01-01T00:00:00+00:00",
        })


def test_leaderboard_three_items(dynamodb_tables, monkeypatch):
    """3 seeded items are returned in the response."""
    monkeypatch.setattr(leaderboard_handler, "leaderboard_snapshot_table",
                        dynamodb_tables["leaderboard_snapshot"])
    _seed_leaderboard(dynamodb_tables["leaderboard_snapshot"], 3)

    event = make_event()
    response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert len(body["leaderboard"]) == 3


def test_leaderboard_empty_table(dynamodb_tables, monkeypatch):
    """Empty leaderboard returns 200 with an empty list."""
    monkeypatch.setattr(leaderboard_handler, "leaderboard_snapshot_table",
                        dynamodb_tables["leaderboard_snapshot"])

    event = make_event()
    response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["leaderboard"] == []
    # version field must always be present
    assert "version" in body


def test_leaderboard_limit_param(dynamodb_tables, monkeypatch):
    """?limit=2 with 5 items returns only 2 results."""
    monkeypatch.setattr(leaderboard_handler, "leaderboard_snapshot_table",
                        dynamodb_tables["leaderboard_snapshot"])
    _seed_leaderboard(dynamodb_tables["leaderboard_snapshot"], 5)

    event = make_event(query_params={"limit": "2"})
    response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert len(body["leaderboard"]) == 2


def test_leaderboard_limit_non_integer(dynamodb_tables, monkeypatch):
    """?limit=abc returns 400."""
    monkeypatch.setattr(leaderboard_handler, "leaderboard_snapshot_table",
                        dynamodb_tables["leaderboard_snapshot"])

    event = make_event(query_params={"limit": "abc"})
    response = handler(event, {})
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "limit" in body["message"].lower()


def test_leaderboard_limit_zero(dynamodb_tables, monkeypatch):
    """?limit=0 returns 400 (must be a positive integer)."""
    monkeypatch.setattr(leaderboard_handler, "leaderboard_snapshot_table",
                        dynamodb_tables["leaderboard_snapshot"])

    event = make_event(query_params={"limit": "0"})
    response = handler(event, {})
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "limit" in body["message"].lower()
