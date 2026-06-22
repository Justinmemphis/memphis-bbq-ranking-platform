"""
Domain models for the Memphis BBQ Ranking Platform.

These are plain Python dataclasses representing core domain entities.
DynamoDB serialization/deserialization is handled separately in each Lambda.
"""

from dataclasses import dataclass, field


@dataclass
class Restaurant:
    restaurant_id: str  # stable slug, e.g. "paynes-bar-b-que" — never changes
    name: str
    location: str
    # Optional detail fields — all stored as strings in DynamoDB
    address: str = ""
    neighborhood: str = ""
    phone: str = ""
    website: str = ""
    style: str = ""          # e.g. "dry rub", "whole hog", "ribs"
    description: str = ""
    lat: str = ""            # decimal string, e.g. "35.1495"
    lng: str = ""            # decimal string, e.g. "-90.0490"
    metadata: dict = field(default_factory=dict)


@dataclass
class Rating:
    user_id: str        # Cognito sub — DynamoDB PK
    restaurant_id: str  # stable slug — DynamoDB SK
    score: int          # 1–5
    created_at: str     # ISO 8601
    updated_at: str     # ISO 8601


@dataclass
class RatingEvent:
    """Append-only audit record written on every rating create/update."""
    restaurant_id: str  # DynamoDB PK
    created_at: str     # DynamoDB SK (ISO 8601, sortable)
    user_id: str
    score: int
    event_type: str     # "created" or "updated"


@dataclass
class LeaderboardEntry:
    scope: str          # e.g. "memphis#all" — DynamoDB PK
    rank: int           # DynamoDB SK
    restaurant_id: str
    score: float        # Bayesian average
    vote_count: int
    version: int        # increments on each snapshot update; used by clients for polling
    algorithm: str = "bayesian_v1"  # stored so future algorithm changes are traceable
