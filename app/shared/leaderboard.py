"""
Shared leaderboard recompute logic.

Centralised here so submit_rating (writes a new rating) and
admin_delete_restaurant (cascade-deletes a restaurant) share one
implementation and can never drift apart.

Algorithm: Bayesian average pulls low-count restaurants toward the prior
mean (3.0) so a single 5-star rating can't dominate the top of the list.
  score = (C * m + sum_of_ratings) / (C + rating_count)
  C = 5 (prior weight), m = 3.0 (prior mean).
"""

import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")
ratings_table = dynamodb.Table(os.environ["RATINGS_TABLE"])
leaderboard_snapshot_table = dynamodb.Table(os.environ["LEADERBOARD_SNAPSHOT_TABLE"])

LEADERBOARD_SCOPE = "memphis#all"
BAYESIAN_C = Decimal("5")
BAYESIAN_M = Decimal("3")
ALGORITHM_VERSION = "bayesian-v1"


def recompute_leaderboard():
    """
    Recomputes leaderboard_snapshot from a full scan of the ratings table.

    Steps:
    1. Scan all ratings — aggregate count and score sum per restaurant.
    2. Compute Bayesian score per restaurant.
    3. Sort descending; assign rank (1 = best).
    4. Delete stale leaderboard items (handles restaurant removal or shrinkage).
    5. Batch-write fresh ranked items.

    Inline call tradeoff: full ratings scan on every write — acceptable at MVP
    scale. Upgrade path: DynamoDB Streams → aggregator Lambda; data model
    unchanged, only the trigger mechanism changes.

    Security: runs under the calling Lambda's IAM role. That role must grant
    Scan on ratings and Query/DeleteItem/PutItem/BatchWriteItem on
    leaderboard_snapshot.
    """
    aggregates = {}

    paginator_kwargs = {}
    while True:
        response = ratings_table.scan(
            ProjectionExpression="restaurant_id, score",
            **paginator_kwargs,
        )
        for item in response.get("Items", []):
            rid = item["restaurant_id"]
            score = Decimal(str(item["score"]))
            if rid not in aggregates:
                aggregates[rid] = {"n": 0, "sum": Decimal("0")}
            aggregates[rid]["n"] += 1
            aggregates[rid]["sum"] += score

        last_key = response.get("LastEvaluatedKey")
        if not last_key:
            break
        paginator_kwargs["ExclusiveStartKey"] = last_key

    if not aggregates:
        # No ratings remain — clear any stale leaderboard entries so the
        # snapshot reflects reality. This happens after a restaurant is deleted.
        existing = leaderboard_snapshot_table.query(
            KeyConditionExpression=Key("scope").eq(LEADERBOARD_SCOPE),
            ProjectionExpression="#r",
            ExpressionAttributeNames={"#r": "rank"},
        )
        for item in existing.get("Items", []):
            leaderboard_snapshot_table.delete_item(
                Key={"scope": LEADERBOARD_SCOPE, "rank": item["rank"]},
            )
        return

    scored = []
    for rid, agg in aggregates.items():
        n = Decimal(str(agg["n"]))
        total = agg["sum"]
        bayesian_score = (BAYESIAN_C * BAYESIAN_M + total) / (BAYESIAN_C + n)
        scored.append({
            "restaurant_id": rid,
            "bayesian_score": bayesian_score,
            "rating_count": int(n),
        })

    scored.sort(key=lambda x: (x["bayesian_score"], x["rating_count"]), reverse=True)
    version = datetime.now(timezone.utc).isoformat()

    existing = leaderboard_snapshot_table.query(
        KeyConditionExpression=Key("scope").eq(LEADERBOARD_SCOPE),
        ProjectionExpression="#r",
        ExpressionAttributeNames={"#r": "rank"},
    )
    for item in existing.get("Items", []):
        leaderboard_snapshot_table.delete_item(
            Key={"scope": LEADERBOARD_SCOPE, "rank": item["rank"]},
        )

    with leaderboard_snapshot_table.batch_writer() as batch:
        for i, entry in enumerate(scored, start=1):
            batch.put_item(Item={
                "scope": LEADERBOARD_SCOPE,
                "rank": i,
                "restaurant_id": entry["restaurant_id"],
                "bayesian_score": entry["bayesian_score"].quantize(Decimal("0.0001")),
                "rating_count": entry["rating_count"],
                "algorithm_version": ALGORITHM_VERSION,
                "version": version,
            })
