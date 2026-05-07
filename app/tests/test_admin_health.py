"""
Unit tests for app/lambdas/admin_health/handler.py

moto 5.0.28 limitation: admin_list_groups_for_user only accepts the Cognito
username (email), not the sub UUID.  The handler passes the sub.  We mock
shared.auth.is_admin directly so these tests validate the HTTP response logic
(200 vs 403) without depending on the moto Cognito sub-lookup behavior.
"""

import json
from unittest.mock import patch

import lambdas.admin_health.handler as admin_health_handler
from lambdas.admin_health.handler import handler
from tests.conftest import make_event


def test_admin_health_admin_caller(monkeypatch):
    """Admin group member receives 200 ok."""
    monkeypatch.setattr(admin_health_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    event = make_event(sub="admin-sub-123")
    with patch("lambdas.admin_health.handler.is_admin", return_value=True):
        response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["status"] == "ok"
    assert body["admin"] is True


def test_admin_health_non_admin_caller(monkeypatch):
    """Non-admin user receives 403 forbidden."""
    monkeypatch.setattr(admin_health_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    event = make_event(sub="regular-sub-456")
    with patch("lambdas.admin_health.handler.is_admin", return_value=False):
        response = handler(event, {})
    assert response["statusCode"] == 403
    body = json.loads(response["body"])
    assert body["error"] == "forbidden"
