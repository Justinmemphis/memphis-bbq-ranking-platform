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
# Prod has its own isolated User Pool — dev and prod never share identity.
# domain_prefix must be globally unique across all AWS accounts.
module "cognito" {
  source        = "../../modules/cognito"
  app_name      = var.app_name
  environment   = var.environment
  domain_prefix = var.cognito_domain_prefix
}

# --- Lambda: health ---
# GET /v1/health — returns caller's sub; used to verify full auth chain.
# Log retention: 90 days for prod (dev uses 14).
module "lambda_health" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name      = "health"
  runtime            = "python3.12"
  source_path        = "${path.root}/../../../app"
  handler            = "lambdas.health.handler.handler"
  log_retention_days = 90
}

# --- Lambda: get_restaurants ---
# GET /v1/restaurants — returns all restaurants from DynamoDB.
# IAM: Scan-only on the restaurants table.
module "lambda_get_restaurants" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name      = "get-restaurants"
  source_path        = "${path.root}/../../../app"
  handler            = "lambdas.get_restaurants.handler.handler"
  log_retention_days = 90

  environment_vars = {
    RESTAURANTS_TABLE = module.dynamodb.restaurants_table_name
  }

  create_additional_policy = true
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
# POST /v1/ratings — upserts a user's rating; appends audit event;
# recomputes the leaderboard inline (Bayesian average).
module "lambda_submit_rating" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name      = "submit-rating"
  source_path        = "${path.root}/../../../app"
  handler            = "lambdas.submit_rating.handler.handler"
  log_retention_days = 90

  environment_vars = {
    RESTAURANTS_TABLE          = module.dynamodb.restaurants_table_name
    RATINGS_TABLE              = module.dynamodb.ratings_table_name
    RATING_EVENTS_TABLE        = module.dynamodb.rating_events_table_name
    LEADERBOARD_SNAPSHOT_TABLE = module.dynamodb.leaderboard_snapshot_table_name
  }

  create_additional_policy = true
  additional_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CheckRestaurantExists"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = module.dynamodb.restaurants_table_arn
      },
      {
        Sid      = "UpsertRating"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = module.dynamodb.ratings_table_arn
      },
      {
        Sid      = "ScanRatingsForRecompute"
        Effect   = "Allow"
        Action   = ["dynamodb:Scan"]
        Resource = module.dynamodb.ratings_table_arn
      },
      {
        Sid      = "AppendRatingEvent"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = module.dynamodb.rating_events_table_arn
      },
      {
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
module "lambda_get_leaderboard" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name      = "get-leaderboard"
  source_path        = "${path.root}/../../../app"
  handler            = "lambdas.get_leaderboard.handler.handler"
  log_retention_days = 90

  environment_vars = {
    LEADERBOARD_SNAPSHOT_TABLE = module.dynamodb.leaderboard_snapshot_table_name
  }

  create_additional_policy = true
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
# IAM: GetItem only on the restaurants table.
module "lambda_get_restaurant_detail" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name      = "get-restaurant-detail"
  source_path        = "${path.root}/../../../app"
  handler            = "lambdas.get_restaurant_detail.handler.handler"
  log_retention_days = 90

  environment_vars = {
    RESTAURANTS_TABLE = module.dynamodb.restaurants_table_name
  }

  create_additional_policy = true
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
# JWT authorizer wires the prod Cognito User Pool as the token validator.
# All routes require a valid Cognito JWT in the Authorization header.
module "api" {
  source      = "../../modules/api_http"
  app_name    = var.app_name
  environment = var.environment

  log_retention_days = 90

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
# Same alarm set as dev (Lambda errors, API 5xx/latency/throttles).
# notification_email passed via TF_VAR_alarm_notification_email env var in CI.
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

# --- WAF WebACL ---
# --- WAF WebACL ---
# Prod has enable_waf = true — WebACL, managed rules, and rate limit are provisioned.
# Association with the API is deferred to Sprint 20 via CloudFront — HTTP APIs
# are not a supported WAFv2 association target (only REST APIs / v1 are supported).
# Rules: AWSManagedRulesCommonRuleSet + AWSManagedRulesKnownBadInputsRuleSet + per-IP rate limit.
# Log retention: 90 days (prod standard).
module "waf" {
  source             = "../../modules/waf"
  app_name           = var.app_name
  environment        = var.environment
  enable_waf         = var.enable_waf
  log_retention_days = 90
}

output "api_endpoint" {
  description = "Base URL for the prod API"
  value       = module.api.api_endpoint
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID (for admin operations)"
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

output "alarms_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms"
  value       = module.alarms.sns_topic_arn
}
