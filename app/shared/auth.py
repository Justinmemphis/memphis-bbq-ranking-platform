"""
Shared auth utilities.

JWT claims are validated by API Gateway's JWT authorizer before the Lambda is invoked.
These helpers extract claim values from the authorizer context — they do NOT perform
any JWT validation themselves (that is API Gateway's job).
"""

import boto3


def get_user_sub(event: dict) -> str:
    """
    Extract the Cognito sub from the API Gateway JWT authorizer context.
    This is the stable, immutable user identity key used everywhere in the data model.
    Returns an empty string if the claim is absent (should not happen on authenticated routes).
    """
    return (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
        .get("sub", "")
    )


def get_user_email(event: dict) -> str:
    """
    Extract the email claim for display purposes only.
    Do NOT use email as a data model key — it is mutable and not guaranteed unique across IdPs.
    """
    return (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
        .get("email", "")
    )


def get_caller_groups(event: dict, user_pool_id: str) -> list:
    """
    Return the Cognito group names for the caller identified by their JWT sub.

    Why server-side check: Cognito does not include group membership in the access
    token by default. Even if configured to do so, a JWT claim could be stale
    (group removed after token issuance). Calling AdminListGroupsForUser is the
    authoritative check.

    Why sub as Username: AdminListGroupsForUser accepts the Cognito sub as the
    Username parameter — it is the same UUID stored as the user's sub attribute.

    Raises on Cognito API error (caller is responsible for catching and returning 500).
    Returns an empty list if the user exists but belongs to no groups.
    """
    client = boto3.client("cognito-idp")
    sub = get_user_sub(event)
    response = client.admin_list_groups_for_user(
        UserPoolId=user_pool_id,
        Username=sub,
    )
    return [g["GroupName"] for g in response.get("Groups", [])]


def is_admin(event: dict, user_pool_id: str) -> bool:
    """
    Return True if the caller is a member of the 'admin' Cognito group.
    Wraps get_caller_groups for the common admin-guard pattern.
    """
    return "admin" in get_caller_groups(event, user_pool_id)
