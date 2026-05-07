"""
Unit tests for app/lambdas/admin_list_users/handler.py

moto 5.0.28 limitation: admin_list_groups_for_user (used by is_admin) only
accepts the Cognito username (email), not the sub UUID.  We mock is_admin
directly and use moto only for the list_users call, which does work correctly.
"""

import json
from unittest.mock import patch

from moto import mock_aws
import boto3

import lambdas.admin_list_users.handler as admin_list_handler
from lambdas.admin_list_users.handler import handler
from tests.conftest import make_event


@mock_aws
def test_admin_list_users_admin_caller(monkeypatch):
    """Admin user receives 200 with a non-empty users list."""
    # Set up a real moto Cognito pool so list_users returns actual data
    client = boto3.client("cognito-idp", region_name="us-east-1")
    pool = client.create_user_pool(PoolName="test-pool")
    pool_id = pool["UserPool"]["Id"]
    client.admin_create_user(UserPoolId=pool_id, Username="user1@example.com",
                              TemporaryPassword="Temp1234!", MessageAction="SUPPRESS")
    client.admin_create_user(UserPoolId=pool_id, Username="user2@example.com",
                              TemporaryPassword="Temp1234!", MessageAction="SUPPRESS")

    monkeypatch.setattr(admin_list_handler, "COGNITO_USER_POOL_ID", pool_id)
    event = make_event(sub="admin-sub-123")
    with patch("lambdas.admin_list_users.handler.is_admin", return_value=True):
        response = handler(event, {})
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert "users" in body
    assert len(body["users"]) == 2


def test_admin_list_users_non_admin(monkeypatch):
    """Non-admin caller receives 403 — no DynamoDB or Cognito calls needed."""
    monkeypatch.setattr(admin_list_handler, "COGNITO_USER_POOL_ID", "test-pool-id")
    event = make_event(sub="regular-sub-456")
    with patch("lambdas.admin_list_users.handler.is_admin", return_value=False):
        response = handler(event, {})
    assert response["statusCode"] == 403
    body = json.loads(response["body"])
    assert body["error"] == "forbidden"
