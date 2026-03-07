"""
Shared auth utilities.

JWT claims are validated by API Gateway's JWT authorizer before the Lambda is invoked.
These helpers extract claim values from the authorizer context — they do NOT perform
any JWT validation themselves (that is API Gateway's job).
"""


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
