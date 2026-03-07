# Module: dynamodb
# Provisions all four application tables with PAY_PER_REQUEST billing.
# Key design: PK/SK choices enforce data integrity constraints at the DB level.
# Security note: encryption at rest is enabled by default on all DynamoDB tables (AWS-managed key).

resource "aws_dynamodb_table" "restaurants" {
  name         = "${var.app_name}-${var.environment}-restaurants"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "restaurant_id"

  attribute {
    name = "restaurant_id"
    type = "S" # stable slug, e.g. "paynes-bar-b-que"
  }
}

resource "aws_dynamodb_table" "ratings" {
  name         = "${var.app_name}-${var.environment}-ratings"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "restaurant_id"

  attribute {
    name = "user_id"     # Cognito sub — immutable identity key
    type = "S"
  }

  attribute {
    name = "restaurant_id"
    type = "S"
  }
  # PK+SK combo enforces one rating per user per restaurant at the table level
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
}
