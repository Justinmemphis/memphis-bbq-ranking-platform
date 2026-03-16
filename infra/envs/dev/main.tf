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
