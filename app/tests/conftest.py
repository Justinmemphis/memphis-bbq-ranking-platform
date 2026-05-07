"""
Shared pytest fixtures for the Memphis BBQ Ranking Platform test suite.

Working directory for pytest is app/ (set in pytest.ini), so imports use
the paths that match Lambda runtime layout: from shared.auth import ...
"""

import os
import sys

import boto3
import pytest
from moto import mock_aws

# Ensure the app/ directory is on sys.path so Lambda-style imports work.
# pytest.ini sets testpaths=tests and is located in app/, so cwd is app/ when
# pytest runs. We insert the parent of tests/ (i.e., app/) onto the path.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# ---------------------------------------------------------------------------
# Stub environment variables required at module-import time
#
# Several handler modules read env vars at the top level (outside any function)
# e.g. `table = dynamodb.Table(os.environ["RESTAURANTS_TABLE"])`.
# Python's import machinery runs these statements during pytest collection,
# before any fixture has had a chance to set the variables.
#
# We set sentinel placeholder values here so the import succeeds.  Each test
# that exercises a handler must then either:
#   (a) use monkeypatch.setattr to replace the module-level Table object, or
#   (b) rely on the fixture to update os.environ before calling the handler.
#
# The boto3.resource("dynamodb").Table(...) call with a placeholder name does
# NOT make a network call — it only creates a local Table descriptor object
# that is resolved at the first actual DynamoDB API call.
# ---------------------------------------------------------------------------
_STUB_ENV = {
    "AWS_DEFAULT_REGION": "us-east-1",
    "RESTAURANTS_TABLE": "stub-restaurants",
    "RATINGS_TABLE": "stub-ratings",
    "RATING_EVENTS_TABLE": "stub-rating-events",
    "LEADERBOARD_SNAPSHOT_TABLE": "stub-leaderboard-snapshot",
    "COGNITO_USER_POOL_ID": "us-east-1_stubpool",
}
for _k, _v in _STUB_ENV.items():
    os.environ.setdefault(_k, _v)

# ---------------------------------------------------------------------------
# Canonical event builder
# ---------------------------------------------------------------------------

def make_event(sub="test-user-sub", email="test@example.com", path_params=None,
               query_params=None, body=None):
    """
    Build a minimal API Gateway HTTP API proxy event matching the shape all
    handlers expect.  Override individual fields in each test as needed.
    """
    return {
        "requestContext": {
            "requestId": "test-request-id",
            "authorizer": {
                "jwt": {
                    "claims": {"sub": sub, "email": email}
                }
            },
        },
        "pathParameters": path_params,
        "queryStringParameters": query_params,
        "body": body,
    }


# ---------------------------------------------------------------------------
# Cognito fixture
# ---------------------------------------------------------------------------

@pytest.fixture
def cognito_pool():
    """
    Creates a moto-backed Cognito User Pool with:
      - a regular user (user_sub)
      - an admin user (admin_sub) who is a member of the 'admin' group

    CRITICAL: moto's admin_list_groups_for_user requires the Username to be
    the Cognito sub, and the user must have been created via admin_create_user
    (not put_user / create_user).  We extract the actual moto-generated sub
    from the admin_create_user response so callers have the exact value needed.

    Yields a dict: {"pool_id": str, "admin_sub": str, "user_sub": str}
    """
    with mock_aws():
        client = boto3.client("cognito-idp", region_name="us-east-1")

        pool = client.create_user_pool(PoolName="test-pool")
        pool_id = pool["UserPool"]["Id"]

        # Create regular user
        regular_resp = client.admin_create_user(
            UserPoolId=pool_id,
            Username="regular@example.com",
            TemporaryPassword="Temp1234!",
            MessageAction="SUPPRESS",
        )
        user_attrs = {a["Name"]: a["Value"]
                      for a in regular_resp["User"]["Attributes"]}
        user_sub = user_attrs["sub"]

        # Create admin user
        admin_resp = client.admin_create_user(
            UserPoolId=pool_id,
            Username="admin@example.com",
            TemporaryPassword="Temp1234!",
            MessageAction="SUPPRESS",
        )
        admin_attrs = {a["Name"]: a["Value"]
                       for a in admin_resp["User"]["Attributes"]}
        admin_sub = admin_attrs["sub"]

        # Create the 'admin' group and add the admin user
        client.create_group(GroupName="admin", UserPoolId=pool_id)
        # admin_add_user_to_group requires the Cognito username (email), not the sub
        client.admin_add_user_to_group(
            UserPoolId=pool_id,
            Username="admin@example.com",
            GroupName="admin",
        )

        os.environ["COGNITO_USER_POOL_ID"] = pool_id

        yield {"pool_id": pool_id, "admin_sub": admin_sub, "user_sub": user_sub}

        # Clean up env var after fixture teardown
        os.environ.pop("COGNITO_USER_POOL_ID", None)


# ---------------------------------------------------------------------------
# DynamoDB fixture
# ---------------------------------------------------------------------------

@pytest.fixture
def dynamodb_tables():
    """
    Creates moto-backed DynamoDB tables matching the production schema:
      - restaurants   (PK: restaurant_id S)
      - ratings       (PK: user_id S, SK: restaurant_id S)
      - rating_events (PK: restaurant_id S, SK: created_at S)
      - leaderboard_snapshot (PK: scope S, SK: rank N)

    Sets all four table-name environment variables and yields a dict of
    boto3 Table objects keyed by logical name.
    """
    with mock_aws():
        dynamodb = boto3.resource("dynamodb", region_name="us-east-1")

        restaurants = dynamodb.create_table(
            TableName="bbq-test-restaurants",
            KeySchema=[{"AttributeName": "restaurant_id", "KeyType": "HASH"}],
            AttributeDefinitions=[
                {"AttributeName": "restaurant_id", "AttributeType": "S"}
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        ratings = dynamodb.create_table(
            TableName="bbq-test-ratings",
            KeySchema=[
                {"AttributeName": "user_id", "KeyType": "HASH"},
                {"AttributeName": "restaurant_id", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "user_id", "AttributeType": "S"},
                {"AttributeName": "restaurant_id", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        rating_events = dynamodb.create_table(
            TableName="bbq-test-rating-events",
            KeySchema=[
                {"AttributeName": "restaurant_id", "KeyType": "HASH"},
                {"AttributeName": "created_at", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "restaurant_id", "AttributeType": "S"},
                {"AttributeName": "created_at", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        # rank is a Number (N) — matches the production schema where rank is the
        # sort key stored as a numeric type for correct numeric ordering.
        leaderboard_snapshot = dynamodb.create_table(
            TableName="bbq-test-leaderboard-snapshot",
            KeySchema=[
                {"AttributeName": "scope", "KeyType": "HASH"},
                {"AttributeName": "rank", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "scope", "AttributeType": "S"},
                {"AttributeName": "rank", "AttributeType": "N"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        os.environ["RESTAURANTS_TABLE"] = "bbq-test-restaurants"
        os.environ["RATINGS_TABLE"] = "bbq-test-ratings"
        os.environ["RATING_EVENTS_TABLE"] = "bbq-test-rating-events"
        os.environ["LEADERBOARD_SNAPSHOT_TABLE"] = "bbq-test-leaderboard-snapshot"

        yield {
            "restaurants": restaurants,
            "ratings": ratings,
            "rating_events": rating_events,
            "leaderboard_snapshot": leaderboard_snapshot,
        }

        for key in ("RESTAURANTS_TABLE", "RATINGS_TABLE",
                    "RATING_EVENTS_TABLE", "LEADERBOARD_SNAPSHOT_TABLE"):
            os.environ.pop(key, None)
