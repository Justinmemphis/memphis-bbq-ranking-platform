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

# --- Lambda: health ---
# GET /v1/health — unauthenticated for this sprint.
# Friday sprint (Sprint 5) adds the Cognito JWT authorizer and updates the
# function to return the caller's sub from JWT claims.
# source_path uses path.root (infra/envs/dev) to navigate to the shared app dir.
module "lambda_health" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name      = "health"
  handler            = "handler.handler"
  runtime            = "python3.12"
  source_path        = "${path.root}/../../../app/lambdas/health"
  log_retention_days = 14
}

# --- API Gateway HTTP API ---
# Routes map wires route keys to Lambda targets.
# New routes added here as Lambda functions are implemented in Phase 2.
module "api" {
  source      = "../../modules/api_http"
  app_name    = var.app_name
  environment = var.environment

  routes = {
    "GET /v1/health" = {
      invoke_arn    = module.lambda_health.invoke_arn
      function_name = module.lambda_health.function_name
    }
  }
}

output "api_endpoint" {
  description = "Base URL for the dev API"
  value       = module.api.api_endpoint
}
