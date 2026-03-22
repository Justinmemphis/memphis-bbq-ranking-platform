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
  }
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
