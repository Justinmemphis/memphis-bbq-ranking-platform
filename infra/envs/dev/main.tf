terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.app_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

module "dynamodb" {
  source      = "../../modules/dynamodb"
  app_name    = var.app_name
  environment = var.environment
}

# --- Cognito User Pool ---
# Each environment has its own isolated User Pool (dev and prod never share identity).
# domain_prefix must be globally unique — set in terraform.tfvars.
module "cognito" {
  source        = "../../modules/cognito"
  app_name      = var.app_name
  environment   = var.environment
  domain_prefix = var.cognito_domain_prefix
}

# --- Lambda: health ---
# GET /v1/health — unauthenticated for this sprint.
# Friday sprint (Sprint 5) adds the Cognito JWT authorizer and updates the
# function to return the caller's sub from JWT claims.
# source_path uses path.root (infra/envs/dev) to navigate to the shared app dir.
module "lambda_health" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name = "health"
  runtime       = "python3.12"
  # source_path is the app/ root — all Lambdas zip the full app tree so that
  # app/shared/ is available to every function without a build step or symlinks.
  # handler uses dot-notation to navigate the package hierarchy.
  source_path        = "${path.root}/../../../app"
  handler            = "lambdas.health.handler.handler"
  log_retention_days = 14
}

# --- Lambda: get_restaurants ---
# GET /v1/restaurants — returns all restaurants from DynamoDB.
# IAM: Scan-only on the restaurants table (no writes, no access to other tables).
# Table name is injected via environment variable — same code runs in dev and prod.
module "lambda_get_restaurants" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name      = "get-restaurants"
  source_path        = "${path.root}/../../../app"
  handler            = "lambdas.get_restaurants.handler.handler"
  log_retention_days = 14

  environment_vars = {
    RESTAURANTS_TABLE = module.dynamodb.restaurants_table_name
  }

  # Least-privilege: only Scan on the restaurants table.
  # Scan is used (vs Query) because there's no GSI to filter by — all restaurants
  # are returned. If a search/filter feature is added, a GSI + Query replaces this.
  additional_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ScanRestaurants"
        Effect   = "Allow"
        Action   = ["dynamodb:Scan"]
        Resource = module.dynamodb.restaurants_table_arn
      },
    ]
  })
}

# --- Lambda: submit_rating ---
# POST /v1/ratings — upserts the caller's rating; appends an audit event;
# recomputes the leaderboard inline (Bayesian average).
# IAM grants are scoped to the minimum needed for all three operations:
#   - restaurants: GetItem only (existence check, no write access)
#   - ratings: PutItem (upsert) + Scan (recompute needs all rows)
#   - rating_events: PutItem (audit append)
#   - leaderboard_snapshot: Query + DeleteItem + PutItem (replace stale snapshot)
# Scan on ratings is the inline recompute cost; the DynamoDB Streams upgrade
# eliminates this scan by triggering the aggregator on each write event.
module "lambda_submit_rating" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name      = "submit-rating"
  source_path        = "${path.root}/../../../app"
  handler            = "lambdas.submit_rating.handler.handler"
  log_retention_days = 14

  environment_vars = {
    RESTAURANTS_TABLE          = module.dynamodb.restaurants_table_name
    RATINGS_TABLE              = module.dynamodb.ratings_table_name
    RATING_EVENTS_TABLE        = module.dynamodb.rating_events_table_name
    LEADERBOARD_SNAPSHOT_TABLE = module.dynamodb.leaderboard_snapshot_table_name
  }

  additional_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read-only existence check — no write access to the restaurants table.
        Sid      = "CheckRestaurantExists"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = module.dynamodb.restaurants_table_arn
      },
      {
        # Upsert the user's rating (PutItem = create or overwrite).
        Sid      = "UpsertRating"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = module.dynamodb.ratings_table_arn
      },
      {
        # Full scan needed for inline Bayesian recompute across all restaurants.
        # Scan scope is limited to this table only — no cross-table access.
        Sid      = "ScanRatingsForRecompute"
        Effect   = "Allow"
        Action   = ["dynamodb:Scan"]
        Resource = module.dynamodb.ratings_table_arn
      },
      {
        # Audit log — append-only, never read or delete from this function.
        Sid      = "AppendRatingEvent"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = module.dynamodb.rating_events_table_arn
      },
      {
        # Leaderboard recompute: query existing ranks, delete stale items,
        # write fresh snapshot. All three actions are required for a clean replace.
        Sid    = "RewriteLeaderboardSnapshot"
        Effect = "Allow"
        Action = [
          "dynamodb:Query",
          "dynamodb:DeleteItem",
          "dynamodb:PutItem",
          "dynamodb:BatchWriteItem",
        ]
        Resource = module.dynamodb.leaderboard_snapshot_table_arn
      },
    ]
  })
}

# --- Lambda: get_leaderboard ---
# GET /v1/leaderboard — reads from leaderboard_snapshot; never touches ratings.
# IAM: Query only on the leaderboard_snapshot table.
# Query (not Scan) is used because scope is the partition key — efficient even
# at large item counts within a scope.
module "lambda_get_leaderboard" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name      = "get-leaderboard"
  source_path        = "${path.root}/../../../app"
  handler            = "lambdas.get_leaderboard.handler.handler"
  log_retention_days = 14

  environment_vars = {
    LEADERBOARD_SNAPSHOT_TABLE = module.dynamodb.leaderboard_snapshot_table_name
  }

  additional_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "QueryLeaderboard"
        Effect   = "Allow"
        Action   = ["dynamodb:Query"]
        Resource = module.dynamodb.leaderboard_snapshot_table_arn
      },
    ]
  })
}

# --- Lambda: get_restaurant_detail ---
# GET /v1/restaurants/{restaurant_id} — single restaurant lookup by slug ID.
# IAM: GetItem only on the restaurants table (no scan, no write access).
module "lambda_get_restaurant_detail" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name      = "get-restaurant-detail"
  source_path        = "${path.root}/../../../app"
  handler            = "lambdas.get_restaurant_detail.handler.handler"
  log_retention_days = 14

  environment_vars = {
    RESTAURANTS_TABLE = module.dynamodb.restaurants_table_name
  }

  additional_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GetRestaurantDetail"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = module.dynamodb.restaurants_table_arn
      },
    ]
  })
}

# --- API Gateway HTTP API ---
# jwt_authorizer wires the Cognito User Pool as the token validator.
# All routes require a valid Cognito JWT in the Authorization header.
# New routes added to the routes map as Lambda functions are implemented in Phase 2.
module "api" {
  source      = "../../modules/api_http"
  app_name    = var.app_name
  environment = var.environment

  jwt_authorizer = {
    issuer   = module.cognito.issuer_url
    audience = [module.cognito.user_pool_client_id]
  }

  routes = {
    "GET /v1/health" = {
      invoke_arn    = module.lambda_health.invoke_arn
      function_name = module.lambda_health.function_name
    }
    "GET /v1/restaurants" = {
      invoke_arn    = module.lambda_get_restaurants.invoke_arn
      function_name = module.lambda_get_restaurants.function_name
    }
    "GET /v1/restaurants/{restaurant_id}" = {
      invoke_arn    = module.lambda_get_restaurant_detail.invoke_arn
      function_name = module.lambda_get_restaurant_detail.function_name
    }
    "GET /v1/leaderboard" = {
      invoke_arn    = module.lambda_get_leaderboard.invoke_arn
      function_name = module.lambda_get_leaderboard.function_name
    }
    "POST /v1/ratings" = {
      invoke_arn    = module.lambda_submit_rating.invoke_arn
      function_name = module.lambda_submit_rating.function_name
    }
  }
}

# --- CloudWatch Alarms + SNS ---
# One error alarm per Lambda function; API Gateway 5xx, latency, and throttle alarms.
# notification_email is set in terraform.tfvars — leave empty to skip email subscription.
# Cost: ~$0.10/alarm/month (~$0.70/month total for this alarm set). SNS email: free tier.
module "alarms" {
  source      = "../../modules/alarms"
  app_name    = var.app_name
  environment = var.environment

  lambda_function_names = [
    module.lambda_health.function_name,
    module.lambda_get_restaurants.function_name,
    module.lambda_get_restaurant_detail.function_name,
    module.lambda_get_leaderboard.function_name,
    module.lambda_submit_rating.function_name,
  ]

  api_gateway_id     = module.api.api_id
  notification_email = var.alarm_notification_email
}

output "alarms_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms"
  value       = module.alarms.sns_topic_arn
}

output "api_endpoint" {
  description = "Base URL for the dev API"
  value       = module.api.api_endpoint
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID (for admin operations and CLI token issuance)"
  value       = module.cognito.user_pool_id
}

output "cognito_client_id" {
  description = "Cognito App Client ID (used as JWT audience)"
  value       = module.cognito.user_pool_client_id
}

output "cognito_hosted_ui_url" {
  description = "Cognito Hosted UI base URL"
  value       = module.cognito.hosted_ui_base_url
}
