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
# Covers: Terraform state (S3 + DynamoDB lock) + DynamoDB app tables
# This policy will be extended as new modules are added.
# Security note: permissions are scoped to specific resource ARNs
# where possible — not wildcards.
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
      # Permissions required for terraform plan and apply on DynamoDB resources
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
    ]
  })
}
