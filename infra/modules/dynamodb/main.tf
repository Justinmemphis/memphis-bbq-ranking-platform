# Module: dynamodb
# Provisions all four application tables with PAY_PER_REQUEST billing.
#
# Key design: PK/SK choices enforce data integrity constraints at the DB level.
#
# Security note: encryption at rest is enabled by default on all DynamoDB tables
# (AWS-managed key). KMS CMK encryption is a Phase 3 prod-hardening item.
#
# Resilience: PITR (point-in-time recovery) is enabled on all tables.
# PITR allows restore to any second in the last 35 days — critical for the
# ratings and rating_events tables where data loss cannot be replayed.
# Cost: ~$0.20/GB/month of backup storage; negligible in dev with minimal data.
# Alternatives: on-demand backups (manual, not continuous); DynamoDB exports to S3
# (cheaper but coarser granularity). PITR is the simplest continuous protection.

resource "aws_dynamodb_table" "restaurants" {
  name         = "${var.app_name}-${var.environment}-restaurants"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "restaurant_id"

  attribute {
    name = "restaurant_id"
    type = "S" # stable slug, e.g. "paynes-bar-b-que"
  }

  # PITR: restaurant data can be rebuilt from seed data, but enabling uniformly
  # keeps the module consistent and satisfies CKV_AWS_28.
  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table" "ratings" {
  name         = "${var.app_name}-${var.environment}-ratings"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "restaurant_id"

  attribute {
    name = "user_id" # Cognito sub — immutable identity key
    type = "S"
  }

  attribute {
    name = "restaurant_id"
    type = "S"
  }
  # PK+SK combo enforces one rating per user per restaurant at the table level

  # PITR: user ratings are the core user-generated data — not rebuildable if lost.
  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table" "rating_events" {
  name         = "${var.app_name}-${var.environment}-rating-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "restaurant_id"
  range_key    = "created_at"

  attribute {
    name = "restaurant_id"
    type = "S"
  }

  attribute {
    name = "created_at" # ISO 8601 — lexicographically sortable
    type = "S"
  }
  # Append-only audit log; items are never updated or deleted

  # PITR: audit log integrity is important for abuse investigation; loss is not
  # acceptable even though this table is append-only.
  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table" "leaderboard_snapshot" {
  name         = "${var.app_name}-${var.environment}-leaderboard-snapshot"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "scope"
  range_key    = "rank"

  attribute {
    name = "scope" # e.g. "memphis#all" — supports future city/category expansion
    type = "S"
  }

  attribute {
    name = "rank"
    type = "N"
  }
  # Denormalized read-optimized snapshot; includes version field for polling clients

  # PITR: leaderboard_snapshot is rebuildable by recompute, but enabling uniformly
  # keeps all tables consistent and avoids a checkov exemption for this one table.
  point_in_time_recovery {
    enabled = true
  }
}
