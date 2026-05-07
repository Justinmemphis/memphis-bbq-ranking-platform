"""
Unit tests for app/lambdas/admin_audit_log/handler.py

admin_audit_log creates its DynamoDB table object INSIDE the handler function
body (dynamodb.Table(RATING_EVENTS_TABLE)), so no monkeypatching of a table
variable is needed — the moto context from dynamodb_tables is sufficient.

is_admin is mocked directly because moto 5.0.28's admin_list_groups_for_user
only accepts the Cognito username (email), not the sub UUID that the handler
passes.  Mocking is_admin tests the handler's HTTP-level logic without
depending on moto's Cognito sub-lookup behavior.
"""

import json
from unittest.mock import patch

import lambdas.admin_audit_log.handler as audit_handler
from lambdas.admin_audit_log.handler import handler
from tests.conftest import make_event

ADMIN_SUB = "admin-sub-abc"
USER_SUB = "user-sub-xyz"


def _seed_event(dynamodb_tables, restaurant_id, created_at, user_id="user-sub-1", score=4):
    dynamodb_tables["rating_events"].put_item(Item={
        "restaurant_id": restaurant_id,
        "created_at": created_at,
        "user_id": user_id,
        "score": score,
    })


def test_audit_log_non_admin(dynamodb_tables, monkeypatch):
    """Non-admin caller receives 403."""
    monkeypatch.setattr(audit_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    event = make_event(
        sub=USER_SUB,
        query_params={"restaurant_id": "paynes-bar-b-que"},
    )
    with patch("lambdas.admin_audit_log.handler.is_admin", return_value=False):
        response = handler(event, {})
    assert response["statusCode"] == 403


def test_audit_log_missing_restaurant_id(dynamodb_tables, monkeypatch):
    """Missing restaurant_id query param returns 400."""
    monkeypatch.setattr(audit_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    event = make_event(sub=ADMIN_SUB)
    with patch("lambdas.admin_audit_log.handler.is_admin", return_value=True):
        response = handler(event, {})
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "restaurant_id" in body["error"].lower()


def test_audit_log_events_returned(dynamodb_tables, monkeypatch):
    """When events exist for a restaurant they are returned in the response."""
    import boto3 as boto3_mod
    monkeypatch.setattr(audit_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    # Patch the module-level dynamodb resource with one created inside the
    # active moto context (dynamodb_tables fixture holds the mock_aws context).
    monkeypatch.setattr(audit_handler, "dynamodb",
                        boto3_mod.resource("dynamodb", region_name="us-east-1"))
    # The handler reads RATING_EVENTS_TABLE at module-import time, capturing
    # the stub value.  We must patch it to the actual moto table name.
    monkeypatch.setattr(audit_handler, "RATING_EVENTS_TABLE", "bbq-test-rating-events")
    _seed_event(dynamodb_tables, "paynes-bar-b-que", "2025-01-01T12:00:00+00:00", score=5)
    _seed_event(dynamodb_tables, "paynes-bar-b-que", "2025-01-02T12:00:00+00:00", score=4)

    event = make_event(
        sub=ADMIN_SUB,
        query_params={"restaurant_id": "paynes-bar-b-que"},
    )
    with patch("lambdas.admin_audit_log.handler.is_admin", return_value=True):
        response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["restaurant_id"] == "paynes-bar-b-que"
    assert len(body["events"]) == 2


def test_audit_log_no_events(dynamodb_tables, monkeypatch):
    """Returns 200 with an empty events list when no events match."""
    import boto3 as boto3_mod
    monkeypatch.setattr(audit_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    monkeypatch.setattr(audit_handler, "dynamodb",
                        boto3_mod.resource("dynamodb", region_name="us-east-1"))
    monkeypatch.setattr(audit_handler, "RATING_EVENTS_TABLE", "bbq-test-rating-events")
    event = make_event(
        sub=ADMIN_SUB,
        query_params={"restaurant_id": "central-bbq"},
    )
    with patch("lambdas.admin_audit_log.handler.is_admin", return_value=True):
        response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["events"] == []
