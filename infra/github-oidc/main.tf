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
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "bbq"
      ManagedBy = "terraform"
    }
  }
}

# Resolve the AWS account ID for use in IAM policy ARNs
data "aws_caller_identity" "current" {}

# -------------------------------------------------------------------
# GitHub Actions OIDC Identity Provider
# Allows GitHub Actions to exchange a short-lived OIDC token for
# temporary AWS credentials — no static access keys required.
# AWS recognises GitHub as a trusted OIDC provider and validates
# tokens against its own CA bundle, but thumbprints are included
# as a defence-in-depth measure.
# -------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub OIDC thumbprints (both current values as of 2024)
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

# -------------------------------------------------------------------
# IAM Role — assumed by GitHub Actions via OIDC
# Trust is scoped to this specific repository only.
# Condition uses StringLike to cover all branches and PR refs.
# -------------------------------------------------------------------
resource "aws_iam_role" "github_actions" {
  name        = "bbq-github-actions"
  description = "Assumed by GitHub Actions via OIDC for Terraform plan/apply"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Scoped to this repo only — any branch or PR ref
            "token.actions.githubusercontent.com:sub" = "repo:Justinmemphis/memphis-bbq-ranking-platform:*"
          }
        }
      }
    ]
  })
}

# -------------------------------------------------------------------
# IAM Policy — least privilege for current Terraform-managed resources
# Covers: Terraform state (S3 + DynamoDB lock), DynamoDB app tables,
#         Lambda functions, API Gateway HTTP API, IAM execution roles,
#         and CloudWatch Logs log groups.
#
# Sprint history:
#   Sprint 2: S3 state + DynamoDB lock + DynamoDB app tables
#   Sprint 4: Lambda + API Gateway + IAM exec roles + CloudWatch Logs
#   Sprint 5: Cognito User Pool + App Client + Hosted UI domain
#   Sprint 12: SNS alarms topic + CloudWatch metric alarms
#
# Security note: permissions are scoped to specific resource ARNs
# where possible. API Gateway ARNs do not include the account ID
# (AWS service quirk) so those statements use a regional wildcard.
# -------------------------------------------------------------------
resource "aws_iam_role_policy" "github_actions" {
  name = "bbq-github-actions-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # --- Terraform remote state: S3 bucket ---
      {
        Sid      = "TerraformStateList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::bbq-tfstate-justin"
      },
      {
        Sid    = "TerraformStateReadWrite"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = "arn:aws:s3:::bbq-tfstate-justin/*"
      },
      # --- Terraform state locking: DynamoDB ---
      {
        Sid    = "TerraformStateLock"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
        ]
        Resource = "arn:aws:dynamodb:us-east-1:${data.aws_caller_identity.current.account_id}:table/bbq-tfstate-lock"
      },
      # --- DynamoDB app tables (bbq-dev-* and bbq-prod-*) ---
      {
        Sid    = "DynamoDBAppTables"
        Effect = "Allow"
        Action = [
          "dynamodb:CreateTable",
          "dynamodb:DeleteTable",
          "dynamodb:DescribeTable",
          "dynamodb:UpdateTable",
          "dynamodb:TagResource",
          "dynamodb:UntagResource",
          "dynamodb:ListTagsOfResource",
          "dynamodb:DescribeContinuousBackups",
          "dynamodb:DescribeTimeToLive",
          "dynamodb:UpdateTimeToLive",
          "dynamodb:UpdateContinuousBackups",
        ]
        Resource = "arn:aws:dynamodb:us-east-1:${data.aws_caller_identity.current.account_id}:table/bbq-*"
      },
      # --- Lambda functions (bbq-dev-* and bbq-prod-*) ---
      # CreateFunction/UpdateFunctionCode: deploy new code on apply.
      # AddPermission/RemovePermission: manage API Gateway invoke permissions.
      # GetFunction/GetPolicy needed by Terraform for drift detection on plan.
      {
        Sid    = "LambdaFunctions"
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction",
          "lambda:DeleteFunction",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:GetFunctionCodeSigningConfig",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:AddPermission",
          "lambda:RemovePermission",
          "lambda:GetPolicy",
          "lambda:ListVersionsByFunction",
          "lambda:TagResource",
          "lambda:UntagResource",
          "lambda:ListTags",
          "lambda:PublishVersion",
        ]
        Resource = "arn:aws:lambda:us-east-1:${data.aws_caller_identity.current.account_id}:function:bbq-*"
      },
      # --- IAM roles for Lambda execution (bbq-*-exec) ---
      # Terraform creates a scoped execution role per Lambda function.
      # PassRole is required when Lambda:CreateFunction references the role.
      # Scoped to bbq-* prefix — prevents creating/modifying unrelated roles.
      {
        Sid    = "IAMExecRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:PassRole",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/bbq-*"
      },
      # --- API Gateway HTTP API ---
      # API Gateway ARNs do not include the account ID — this is an AWS quirk
      # for the apigateway service. Scoped to us-east-1 only.
      # Covers the API, stages, routes, and Lambda integrations.
      {
        Sid    = "APIGateway"
        Effect = "Allow"
        Action = [
          "apigateway:GET",
          "apigateway:POST",
          "apigateway:PUT",
          "apigateway:PATCH",
          "apigateway:DELETE",
          "apigateway:TagResource",
          "apigateway:UntagResource",
        ]
        Resource = "arn:aws:apigateway:us-east-1::*"
      },
      # --- Cognito User Pool management ---
      # Split into two statements because CreateUserPool and ListUserPools do not
      # support resource-level ARNs (AWS restriction) — they require "*".
      # All other user pool operations are scoped to the userpool/* ARN pattern.
      #
      # Sprint 5: added to support terraform plan/apply for the cognito module.
      # Security note: CreateUserPool is gated to us-east-1 only via the provider;
      # the "*" resource is an AWS limitation, not a policy choice.
      {
        Sid    = "CognitoGlobal"
        Effect = "Allow"
        Action = [
          "cognito-idp:CreateUserPool",
          "cognito-idp:ListUserPools",
          # DescribeUserPoolDomain operates on the domain (not userpool ARN) —
          # AWS requires Resource: "*" for this call; userpool/* scope is rejected.
          "cognito-idp:DescribeUserPoolDomain",
        ]
        Resource = "*"
      },
      {
        Sid    = "CognitoUserPool"
        Effect = "Allow"
        Action = [
          "cognito-idp:DeleteUserPool",
          "cognito-idp:DescribeUserPool",
          "cognito-idp:UpdateUserPool",
          "cognito-idp:SetUserPoolMfaConfig",
          "cognito-idp:GetUserPoolMfaConfig",
          "cognito-idp:CreateUserPoolClient",
          "cognito-idp:DeleteUserPoolClient",
          "cognito-idp:UpdateUserPoolClient",
          "cognito-idp:DescribeUserPoolClient",
          "cognito-idp:ListUserPoolClients",
          "cognito-idp:CreateUserPoolDomain",
          "cognito-idp:DeleteUserPoolDomain",
          "cognito-idp:TagResource",
          "cognito-idp:UntagResource",
          "cognito-idp:ListTagsForResource",
        ]
        Resource = "arn:aws:cognito-idp:us-east-1:${data.aws_caller_identity.current.account_id}:userpool/*"
      },
      # --- CloudWatch Logs: log groups for Lambda and API Gateway ---
      # DescribeLogGroups uses * because the Describe API does not accept
      # specific log group ARNs in IAM resource conditions (AWS limitation).
      # Create/Delete/PutRetentionPolicy are scoped to bbq-prefixed groups.
      {
        Sid      = "CloudWatchLogsDescribe"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogsManage"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:PutRetentionPolicy",
          "logs:DeleteRetentionPolicy",
          "logs:ListTagsForResource",
          "logs:ListTagsLogGroup",
          "logs:TagLogGroup",
          "logs:UntagLogGroup",
          "logs:TagResource",
          "logs:UntagResource",
        ]
        Resource = [
          "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/bbq-*",
          "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/apigateway/bbq-*",
        ]
      },
      # --- SNS: alarms topic (Sprint 12) ---
      # Terraform needs GetTopicAttributes to refresh SNS topic state during plan.
      # GetSubscriptionAttributes/SetSubscriptionAttributes needed to refresh and
      # manage email subscription state (subscription ARNs also match bbq-* prefix).
      # Publish is not granted here — Lambda execution roles handle that separately.
      # Scoped to bbq-prefixed topics and subscriptions only.
      {
        Sid    = "SNSManage"
        Effect = "Allow"
        Action = [
          "sns:GetTopicAttributes",
          "sns:SetTopicAttributes",
          "sns:CreateTopic",
          "sns:DeleteTopic",
          "sns:ListTagsForResource",
          "sns:TagResource",
          "sns:UntagResource",
          "sns:Subscribe",
          "sns:Unsubscribe",
          "sns:ListSubscriptionsByTopic",
          "sns:GetSubscriptionAttributes",
          "sns:SetSubscriptionAttributes",
        ]
        Resource = "arn:aws:sns:us-east-1:${data.aws_caller_identity.current.account_id}:bbq-*"
      },
      # --- CloudWatch Alarms (Sprint 12) ---
      # Terraform needs Describe/Put/Delete to manage metric alarms.
      # Scoped to bbq-prefixed alarms only.
      {
        Sid    = "CloudWatchAlarmsManage"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarms",
          "cloudwatch:PutMetricAlarm",
          "cloudwatch:DeleteAlarms",
          "cloudwatch:ListTagsForResource",
          "cloudwatch:TagResource",
          "cloudwatch:UntagResource",
        ]
        Resource = "arn:aws:cloudwatch:us-east-1:${data.aws_caller_identity.current.account_id}:alarm:bbq-*"
      },
      # --- WAF v2 WebACL (Sprint 15 — prod-only) ---
      # Required for aws_wafv2_web_acl, aws_wafv2_web_acl_logging_configuration,
      # and aws_wafv2_web_acl_association resources.
      # Resource ARN format: arn:aws:wafv2:region:account:regional/webacl/name/id
      # The trailing /* covers the generated ID segment (unknown at plan time).
      # Scoped to bbq-prefixed WebACLs in us-east-1 only.
      {
        Sid    = "WAFWebACL"
        Effect = "Allow"
        Action = [
          "wafv2:CreateWebACL",
          "wafv2:DeleteWebACL",
          "wafv2:GetWebACL",
          "wafv2:UpdateWebACL",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:PutLoggingConfiguration",
          "wafv2:GetLoggingConfiguration",
          "wafv2:DeleteLoggingConfiguration",
          "wafv2:ListTagsForResource",
          "wafv2:TagResource",
          "wafv2:UntagResource",
        ]
        Resource = "arn:aws:wafv2:us-east-1:${data.aws_caller_identity.current.account_id}:regional/webacl/bbq-*/*"
      },
      # --- CloudWatch log resource policy (Sprint 15 — WAF logging) ---
      # aws_cloudwatch_log_resource_policy (used to grant WAF delivery.logs access)
      # requires PutResourcePolicy/DeleteResourcePolicy.
      # AWS does not support resource-level ARN scoping for these actions —
      # Resource = "*" is an AWS service limitation, not a policy choice.
      # DescribeResourcePolicies is needed by Terraform to read current policy state.
      {
        Sid    = "CloudWatchLogResourcePolicy"
        Effect = "Allow"
        Action = [
          "logs:PutResourcePolicy",
          "logs:DeleteResourcePolicy",
          "logs:DescribeResourcePolicies",
        ]
        Resource = "*"
      },
      # --- CloudWatch Logs: WAF log group (Sprint 15) ---
      # WAF log group name must start with 'aws-waf-logs-' (AWS requirement).
      # This pattern is separate from Lambda/API Gateway log groups above.
      {
        Sid    = "CloudWatchLogsWAF"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:PutRetentionPolicy",
          "logs:DeleteRetentionPolicy",
          "logs:ListTagsForResource",
          "logs:ListTagsLogGroup",
          "logs:TagLogGroup",
          "logs:UntagLogGroup",
          "logs:TagResource",
          "logs:UntagResource",
        ]
        Resource = "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:aws-waf-logs-bbq-*"
      },
    ]
  })
}
