# Module: lambda
#
# Provisions a single Lambda function with a least-privilege execution role
# and a pre-created CloudWatch log group.
#
# Design decisions:
#   - Log group is created by Terraform (not auto-created by Lambda) so retention
#     is set on the very first invocation. Without this, Lambda creates an indefinitely
#     retained log group that accumulates cost silently.
#   - IAM role is function-scoped (not shared). Sharing roles across functions violates
#     least privilege — one over-permissioned function would expose all others.
#   - source_code_hash ties the deploy to the zip content hash; Terraform only
#     re-deploys when code actually changes, not on every plan.
#   - dynamic environment block is omitted when no vars are supplied; an empty
#     environment block causes a Terraform API error on some runtime versions.
#
# Security implications:
#   - The execution role only allows CloudWatch Logs writes to its own log group ARN
#     (not a wildcard). Additional permissions (e.g., DynamoDB) are added per-function
#     in the calling environment.
#   - Lambda trusts only the Lambda service principal — no cross-account assumptions.

locals {
  full_name = "${var.app_name}-${var.environment}-${var.function_name}"
}

# --- Code packaging ---
# archive_file zips the source directory locally at plan time.
# output_path is scoped under path.root (the env directory) to keep
# build artifacts co-located with the env, not polluting the module.
# The zip is gitignored via lambda-packages/ in .gitignore.
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = var.source_path
  output_path = "${path.root}/lambda-packages/${var.function_name}.zip"
}

# --- CloudWatch log group ---
# Created before the function. Lambda would auto-create it on first invocation,
# but with no retention policy — this way retention is set from day one.
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.full_name}"
  retention_in_days = var.log_retention_days
}

# --- IAM execution role ---
# Trust policy: only the Lambda service can assume this role.
# One role per function — never shared across functions.
resource "aws_iam_role" "lambda" {
  name        = "${local.full_name}-exec"
  description = "Execution role for Lambda function ${local.full_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# --- IAM policy: CloudWatch Logs ---
# Scoped to this function's log group ARN only — not a wildcard.
# CreateLogStream + PutLogEvents are the minimum Lambda needs to write structured logs.
resource "aws_iam_role_policy" "lambda_logs" {
  name = "${local.full_name}-logs"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        # :* suffix targets log streams within this log group
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      },
    ]
  })
}

# --- Lambda function ---
# depends_on log group: ensures the log group (with retention) exists before
# the function is created, preventing the auto-creation race condition.
resource "aws_lambda_function" "this" {
  function_name    = local.full_name
  role             = aws_iam_role.lambda.arn
  handler          = var.handler
  runtime          = var.runtime
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  # Only inject the environment block when vars are actually provided.
  # An empty environment block causes API errors on certain runtimes.
  dynamic "environment" {
    for_each = length(var.environment_vars) > 0 ? [1] : []
    content {
      variables = var.environment_vars
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}
