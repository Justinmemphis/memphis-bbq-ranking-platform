# Module: dynamodb
# Provisions DynamoDB tables:
#   - restaurants  (PK: restaurant_id)
#   - ratings      (PK: user_id, SK: restaurant_id) — one rating per user per restaurant
#   - rating_events (PK: restaurant_id, SK: created_at) — append-only audit log
#   - leaderboard_snapshot (PK: scope, SK: rank) — denormalized read-optimized snapshot
# All tables use PAY_PER_REQUEST billing.
# TODO: implement in Phase 1/2
