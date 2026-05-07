"""
Unit tests for app/lambdas/health/handler.py
"""

import json

from lambdas.health.handler import handler
from tests.conftest import make_event


def test_health_happy_path():
    """Returns 200 and echoes the caller's sub."""
    event = make_event(sub="user-abc-123")
    response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["status"] == "ok"
    assert body["sub"] == "user-abc-123"


def test_health_missing_authorizer():
    """
    When the authorizer context is absent the handler falls back to
    'unauthenticated' — it does NOT return 401.  The JWT check is
    handled by API Gateway before the Lambda is ever invoked.
    """
    response = handler({}, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["sub"] == "unauthenticated"
