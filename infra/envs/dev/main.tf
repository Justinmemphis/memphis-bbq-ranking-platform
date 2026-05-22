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

  # Admin UI callback: CloudFront domain is known at apply time after static_site runs.
  # Cognito app client depends on static_site; Terraform resolves the order automatically.
  callback_urls = [
    "http://localhost",
    "http://localhost:3000/callback",
    "https://${module.static_site.cloudfront_domain_name}/index.html",
    "https://${module.static_site.cloudfront_domain_name}/admin/index.html",
  ]
  logout_urls = [
    "http://localhost",
    "http://localhost:3000",
    "https://${module.static_site.cloudfront_domain_name}/index.html",
    "https://${module.static_site.cloudfront_domain_name}/admin/index.html",
  ]
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

  create_additional_policy = true
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
      public        = true
    }
    "GET /v1/restaurants/{restaurant_id}" = {
      invoke_arn    = module.lambda_get_restaurant_detail.invoke_arn
      function_name = module.lambda_get_restaurant_detail.function_name
      public        = true
    }
    "GET /v1/leaderboard" = {
      invoke_arn    = module.lambda_get_leaderboard.invoke_arn
      function_name = module.lambda_get_leaderboard.function_name
      public        = true
    }
    "POST /v1/ratings" = {
      invoke_arn    = module.lambda_submit_rating.invoke_arn
      function_name = module.lambda_submit_rating.function_name
    }
    "GET /v1/admin/health" = {
      invoke_arn    = module.lambda_admin_health.invoke_arn
      function_name = module.lambda_admin_health.function_name
    }
    "GET /v1/admin/users" = {
      invoke_arn    = module.lambda_admin_list_users.invoke_arn
      function_name = module.lambda_admin_list_users.function_name
    }
    "POST /v1/admin/users/{sub}/action" = {
      invoke_arn    = module.lambda_admin_manage_user.invoke_arn
      function_name = module.lambda_admin_manage_user.function_name
    }
    "GET /v1/admin/audit-log" = {
      invoke_arn    = module.lambda_admin_audit_log.invoke_arn
      function_name = module.lambda_admin_audit_log.function_name
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
    module.lambda_admin_health.function_name,
    module.lambda_admin_list_users.function_name,
    module.lambda_admin_manage_user.function_name,
    module.lambda_admin_audit_log.function_name,
  ]

  api_gateway_id                = module.api.api_id
  notification_email            = var.alarm_notification_email
  submit_rating_function_name   = module.lambda_submit_rating.function_name
  admin_audit_log_function_name = module.lambda_admin_audit_log.function_name
  cognito_user_pool_id          = module.cognito.user_pool_id
  cognito_user_pool_client_id   = module.cognito.user_pool_client_id
  rating_spike_threshold        = 50
}

# --- WAF WebACL ---
# Dev intentionally has enable_waf = false — WAF costs ~$5/month regardless of traffic.
# Module call mirrors prod structure; no resources are created when enable_waf = false.
# WAF association with CloudFront is wired in Sprint 22 (CLOUDFRONT scope WebACL).
module "waf" {
  source             = "../../modules/waf"
  app_name           = var.app_name
  environment        = var.environment
  enable_waf         = var.enable_waf
  log_retention_days = 14
}

# --- Static Site: S3 + CloudFront ---
# Dev mirrors prod — CloudFront has no fixed monthly fee so there is no cost justification
# for an environment gap. WAF is not enabled in dev (enable_waf = false), so
# module.waf.web_acl_arn is null and no WAF WebACL is attached to the CloudFront distribution.
module "static_site" {
  source            = "../../modules/static_site"
  app_name          = var.app_name
  environment       = var.environment
  enable_cloudfront = var.enable_cloudfront
  web_acl_id        = module.waf.web_acl_arn
}

# Deploy stub index.html — same as prod; etag tracks file changes.
resource "aws_s3_object" "index_html" {
  count = var.enable_cloudfront ? 1 : 0

  bucket       = module.static_site.s3_bucket_name
  key          = "index.html"
  source       = "${path.root}/../../../static/index.html"
  content_type = "text/html"
  etag         = filemd5("${path.root}/../../../static/index.html")
}

# --- Public landing page: S3 deployment ---
resource "aws_s3_object" "public_js" {
  count        = var.enable_cloudfront ? 1 : 0
  bucket       = module.static_site.s3_bucket_name
  key          = "app.js"
  source       = "${path.root}/../../../static/app.js"
  content_type = "application/javascript"
  etag         = filemd5("${path.root}/../../../static/app.js")
}

resource "aws_s3_object" "public_config" {
  count        = var.enable_cloudfront ? 1 : 0
  bucket       = module.static_site.s3_bucket_name
  key          = "config.json"
  content_type = "application/json"
  content = jsonencode({
    api_endpoint      = module.api.api_endpoint
    cognito_domain    = "${var.cognito_domain_prefix}.auth.us-east-1.amazoncognito.com"
    cognito_client_id = module.cognito.user_pool_client_id
    redirect_uri      = "https://${module.static_site.cloudfront_domain_name}/index.html"
  })
  etag = md5(jsonencode({
    api_endpoint      = module.api.api_endpoint
    cognito_domain    = "${var.cognito_domain_prefix}.auth.us-east-1.amazoncognito.com"
    cognito_client_id = module.cognito.user_pool_client_id
    redirect_uri      = "https://${module.static_site.cloudfront_domain_name}/index.html"
  }))
}

# --- Admin UI: S3 deployment ---
# Three static files: index.html, admin.js, style.css
# config.json is generated by Terraform from outputs so the JS does not need
# environment-specific values hardcoded. CloudFront serves all files under /admin/.
resource "aws_s3_object" "admin_index_html" {
  count        = var.enable_cloudfront ? 1 : 0
  bucket       = module.static_site.s3_bucket_name
  key          = "admin/index.html"
  source       = "${path.root}/../../../app/admin/index.html"
  content_type = "text/html"
  etag         = filemd5("${path.root}/../../../app/admin/index.html")
}

resource "aws_s3_object" "admin_js" {
  count        = var.enable_cloudfront ? 1 : 0
  bucket       = module.static_site.s3_bucket_name
  key          = "admin/admin.js"
  source       = "${path.root}/../../../app/admin/admin.js"
  content_type = "application/javascript"
  etag         = filemd5("${path.root}/../../../app/admin/admin.js")
}

resource "aws_s3_object" "admin_css" {
  count        = var.enable_cloudfront ? 1 : 0
  bucket       = module.static_site.s3_bucket_name
  key          = "admin/style.css"
  source       = "${path.root}/../../../app/admin/style.css"
  content_type = "text/css"
  etag         = filemd5("${path.root}/../../../app/admin/style.css")
}

# config.json: Terraform generates this from outputs so the admin JS knows
# the API endpoint, Cognito domain, and client ID without hardcoding.
# etag on a content-derived value ensures re-upload when values change.
resource "aws_s3_object" "admin_config" {
  count        = var.enable_cloudfront ? 1 : 0
  bucket       = module.static_site.s3_bucket_name
  key          = "admin/config.json"
  content_type = "application/json"
  content = jsonencode({
    api_endpoint      = module.api.api_endpoint
    cognito_domain    = "${var.cognito_domain_prefix}.auth.us-east-1.amazoncognito.com"
    cognito_client_id = module.cognito.user_pool_client_id
    redirect_uri      = "https://${module.static_site.cloudfront_domain_name}/admin/index.html"
  })
  etag = md5(jsonencode({
    api_endpoint      = module.api.api_endpoint
    cognito_domain    = "${var.cognito_domain_prefix}.auth.us-east-1.amazoncognito.com"
    cognito_client_id = module.cognito.user_pool_client_id
    redirect_uri      = "https://${module.static_site.cloudfront_domain_name}/admin/index.html"
  }))
}

# --- Lambda: admin_audit_log ---
# GET /v1/admin/audit-log?restaurant_id=X — queries rating_events by restaurant. Admin-only.
# IAM: Query on rating_events ARN + AdminListGroupsForUser on User Pool.
module "lambda_admin_audit_log" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name      = "admin-audit-log"
  source_path        = "${path.root}/../../../app"
  handler            = "lambdas.admin_audit_log.handler.handler"
  log_retention_days = 14

  environment_vars = {
    COGNITO_USER_POOL_ID = module.cognito.user_pool_id
    RATING_EVENTS_TABLE  = module.dynamodb.rating_events_table_name
  }

  create_additional_policy = true
  additional_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "QueryRatingEvents"
        Effect   = "Allow"
        Action   = ["dynamodb:Query"]
        Resource = module.dynamodb.rating_events_table_arn
      },
      {
        Sid      = "ListGroupsForUser"
        Effect   = "Allow"
        Action   = ["cognito-idp:AdminListGroupsForUser"]
        Resource = module.cognito.user_pool_arn
      },
    ]
  })
}

# --- Lambda: admin_list_users ---
# GET /v1/admin/users — returns Cognito user list. Admin-only.
# IAM: ListUsers + AdminListGroupsForUser on this User Pool only.
module "lambda_admin_list_users" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name      = "admin-list-users"
  source_path        = "${path.root}/../../../app"
  handler            = "lambdas.admin_list_users.handler.handler"
  log_retention_days = 14

  environment_vars = {
    COGNITO_USER_POOL_ID = module.cognito.user_pool_id
  }

  create_additional_policy = true
  additional_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AdminUserOps"
        Effect = "Allow"
        Action = [
          "cognito-idp:ListUsers",
          "cognito-idp:AdminListGroupsForUser",
        ]
        Resource = module.cognito.user_pool_arn
      },
    ]
  })
}

# --- Lambda: admin_manage_user ---
# POST /v1/admin/users/{sub}/action — disable, enable, or force-reset a user. Admin-only.
# IAM: AdminDisableUser + AdminEnableUser + AdminResetUserPassword + AdminListGroupsForUser.
module "lambda_admin_manage_user" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name      = "admin-manage-user"
  source_path        = "${path.root}/../../../app"
  handler            = "lambdas.admin_manage_user.handler.handler"
  log_retention_days = 14

  environment_vars = {
    COGNITO_USER_POOL_ID = module.cognito.user_pool_id
  }

  create_additional_policy = true
  additional_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AdminUserMgmt"
        Effect = "Allow"
        Action = [
          "cognito-idp:AdminDisableUser",
          "cognito-idp:AdminEnableUser",
          "cognito-idp:AdminResetUserPassword",
          "cognito-idp:AdminListGroupsForUser",
        ]
        Resource = module.cognito.user_pool_arn
      },
    ]
  })
}

# --- Lambda: admin_health ---
# GET /v1/admin/health — smoke-test for the admin group guard.
# Returns 200 for members of the 'admin' Cognito group; 403 for all others.
# IAM: AdminListGroupsForUser scoped to this environment's User Pool ARN only.
module "lambda_admin_health" {
  source      = "../../modules/lambda"
  app_name    = var.app_name
  environment = var.environment

  function_name      = "admin-health"
  source_path        = "${path.root}/../../../app"
  handler            = "lambdas.admin_health.handler.handler"
  log_retention_days = 14

  environment_vars = {
    COGNITO_USER_POOL_ID = module.cognito.user_pool_id
  }

  # AdminListGroupsForUser: verify group membership server-side at request time.
  # Scoped to this User Pool ARN — not a wildcard.
  create_additional_policy = true
  additional_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListGroupsForUser"
        Effect   = "Allow"
        Action   = ["cognito-idp:AdminListGroupsForUser"]
        Resource = module.cognito.user_pool_arn
      },
    ]
  })
}

output "alarms_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms"
  value       = module.alarms.sns_topic_arn
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name (empty when enable_cloudfront = false)"
  value       = module.static_site.cloudfront_domain_name
}

output "static_site_bucket" {
  description = "Static site S3 bucket name (empty when enable_cloudfront = false)"
  value       = module.static_site.s3_bucket_name
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
