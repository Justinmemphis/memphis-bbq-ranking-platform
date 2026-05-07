"""
Unit tests for app/shared/auth.py

Note on is_admin / get_caller_groups:
  moto 5.0.28's admin_list_groups_for_user only accepts the Cognito username
  (email), not the sub UUID — unlike real AWS which accepts either.
  The handler calls it with the sub. Rather than relying on moto to support
  sub-as-username (it doesn't in this version), we test is_admin by mocking
  get_caller_groups, which is the correct unit-test boundary: auth.py's logic
  is "is 'admin' in the groups list?" — not "does the Cognito SDK call work?".
  The Cognito SDK path is an integration concern tested end-to-end.
"""

from unittest.mock import patch

from shared.auth import get_user_email, get_user_sub, is_admin
from tests.conftest import make_event


# ---------------------------------------------------------------------------
# get_user_sub
# ---------------------------------------------------------------------------

def test_get_user_sub_present():
    event = make_event(sub="abc-123")
    assert get_user_sub(event) == "abc-123"


def test_get_user_sub_missing():
    """Returns empty string when authorizer context is absent."""
    assert get_user_sub({}) == ""


def test_get_user_sub_empty_claims():
    event = {"requestContext": {"authorizer": {"jwt": {"claims": {}}}}}
    assert get_user_sub(event) == ""


# ---------------------------------------------------------------------------
# get_user_email
# ---------------------------------------------------------------------------

def test_get_user_email_present():
    event = make_event(email="bbq@memphis.com")
    assert get_user_email(event) == "bbq@memphis.com"


def test_get_user_email_missing():
    assert get_user_email({}) == ""


# ---------------------------------------------------------------------------
# is_admin
#
# is_admin() delegates to get_caller_groups() which calls the Cognito API.
# We mock get_caller_groups so this test stays a pure unit test of the
# "is 'admin' in groups?" logic, independent of Cognito SDK behavior.
# ---------------------------------------------------------------------------

def test_is_admin_true():
    """Returns True when caller's groups include 'admin'."""
    event = make_event(sub="some-admin-sub")
    with patch("shared.auth.get_caller_groups", return_value=["admin", "users"]):
        result = is_admin(event, "us-east-1_fake")
    assert result is True


def test_is_admin_false():
    """Returns False when caller is not in the 'admin' group."""
    event = make_event(sub="regular-user-sub")
    with patch("shared.auth.get_caller_groups", return_value=["users"]):
        result = is_admin(event, "us-east-1_fake")
    assert result is False
