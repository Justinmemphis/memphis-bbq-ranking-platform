"""
Unit tests for app/lambdas/admin_manage_user/handler.py

moto 5.0.28 limitation: admin_disable_user / admin_enable_user /
admin_reset_user_password all require the Cognito username (email), not the
sub UUID.  The handler passes the sub (correct for real AWS).  We mock the
boto3 cognito-idp client used inside the handler so tests exercise the handler
logic without hitting moto's username-only restriction.

is_admin is also mocked for the same reason.
"""

import json
from unittest.mock import MagicMock, patch
from botocore.exceptions import ClientError

import lambdas.admin_manage_user.handler as manage_handler
from lambdas.admin_manage_user.handler import handler
from tests.conftest import make_event

TARGET_SUB = "target-user-sub-9999"
ADMIN_SUB = "admin-sub-1234"


def _admin_event(body, target=TARGET_SUB):
    return make_event(
        sub=ADMIN_SUB,
        path_params={"sub": target},
        body=body,
    )


def test_manage_user_non_admin(monkeypatch):
    """Non-admin caller receives 403."""
    monkeypatch.setattr(manage_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    event = _admin_event(json.dumps({"action": "disable"}), target=TARGET_SUB)
    # Override caller to be a non-admin
    event["requestContext"]["authorizer"]["jwt"]["claims"]["sub"] = "regular-sub"
    with patch("lambdas.admin_manage_user.handler.is_admin", return_value=False):
        response = handler(event, {})
    assert response["statusCode"] == 403


def test_manage_user_invalid_json_body(monkeypatch):
    """Invalid JSON body returns 400 (checked after admin guard)."""
    monkeypatch.setattr(manage_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    event = _admin_event("not-valid-json{{{")
    with patch("lambdas.admin_manage_user.handler.is_admin", return_value=True):
        response = handler(event, {})
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "json" in body["error"].lower()


def test_manage_user_invalid_action(monkeypatch):
    """An action not in {disable, enable, force_reset} returns 400."""
    monkeypatch.setattr(manage_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    event = _admin_event(json.dumps({"action": "delete"}))
    with patch("lambdas.admin_manage_user.handler.is_admin", return_value=True):
        response = handler(event, {})
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "action" in body["error"].lower()


def test_manage_user_self_disable(monkeypatch):
    """Admin cannot disable their own account — returns 400."""
    monkeypatch.setattr(manage_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    # target_sub == caller_sub
    event = make_event(
        sub=ADMIN_SUB,
        path_params={"sub": ADMIN_SUB},
        body=json.dumps({"action": "disable"}),
    )
    with patch("lambdas.admin_manage_user.handler.is_admin", return_value=True):
        response = handler(event, {})
    assert response["statusCode"] == 400
    body = json.loads(response["body"])
    assert "cannot disable" in body["error"].lower()


def test_manage_user_disable_valid_user(monkeypatch):
    """Admin can disable a different user — returns 200."""
    monkeypatch.setattr(manage_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    mock_client = MagicMock()
    event = _admin_event(json.dumps({"action": "disable"}))
    with patch("lambdas.admin_manage_user.handler.is_admin", return_value=True), \
         patch("lambdas.admin_manage_user.handler.boto3.client", return_value=mock_client):
        response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["action"] == "disable"
    mock_client.admin_disable_user.assert_called_once_with(
        UserPoolId="test-pool-id", Username=TARGET_SUB
    )


def test_manage_user_enable_valid_user(monkeypatch):
    """Admin can enable a user — returns 200."""
    monkeypatch.setattr(manage_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    mock_client = MagicMock()
    event = _admin_event(json.dumps({"action": "enable"}))
    with patch("lambdas.admin_manage_user.handler.is_admin", return_value=True), \
         patch("lambdas.admin_manage_user.handler.boto3.client", return_value=mock_client):
        response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["action"] == "enable"
    mock_client.admin_enable_user.assert_called_once_with(
        UserPoolId="test-pool-id", Username=TARGET_SUB
    )


def test_manage_user_force_reset_valid_user(monkeypatch):
    """Admin can force password reset for another user — returns 200."""
    monkeypatch.setattr(manage_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    mock_client = MagicMock()
    event = _admin_event(json.dumps({"action": "force_reset"}))
    with patch("lambdas.admin_manage_user.handler.is_admin", return_value=True), \
         patch("lambdas.admin_manage_user.handler.boto3.client", return_value=mock_client):
        response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["action"] == "force_reset"
    mock_client.admin_reset_user_password.assert_called_once_with(
        UserPoolId="test-pool-id", Username=TARGET_SUB
    )


def test_manage_user_nonexistent_user(monkeypatch):
    """Action on a user that does not exist returns 404."""
    monkeypatch.setattr(manage_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    mock_client = MagicMock()
    not_found_error = ClientError(
        {"Error": {"Code": "UserNotFoundException", "Message": "User does not exist."}},
        "AdminDisableUser",
    )
    mock_client.admin_disable_user.side_effect = not_found_error
    event = _admin_event(json.dumps({"action": "disable"}))
    with patch("lambdas.admin_manage_user.handler.is_admin", return_value=True), \
         patch("lambdas.admin_manage_user.handler.boto3.client", return_value=mock_client):
        response = handler(event, {})
    assert response["statusCode"] == 404
    body = json.loads(response["body"])
    assert "not found" in body["error"].lower()
