# Module: api_http
#
# Provisions an API Gateway HTTP API (v2) with Lambda proxy integrations.
# Routes are passed in as a map, making this module reusable as new Lambda
# functions are added in Phase 2.
#
# Design decisions:
#   - HTTP API (v2) over REST API (v1): lower cost (~70%), built-in JWT authorizer,
#     simpler config. REST API adds features we don't need at this stage (e.g.,
#     request validation, usage plans). Switching later would require a redeploy
#     but not a data model change.
#   - $default stage with auto_deploy: removes the manual deploy step on every
#     change. Fine for dev/prod at this scale; a blue/green stage strategy would
#     be added in Phase 4 if needed.
#   - CORS allow_origins = ["*"] for now — tightened to the CloudFront domain
#     in Phase 3 once the static site module is wired in.
#   - Lambda permissions (aws_lambda_permission) live here, not in the Lambda
#     module. The permission needs the API's execution ARN (only known here),
#     and the function name is passed in via the routes map. This avoids a
#     circular dependency between the two modules.
#   - Access logs go to a CloudWatch log group created by Terraform (not
#     auto-created by API Gateway) so retention is controlled from day one.
#     HTTP API v2 does NOT require an account-level CloudWatch role ARN
#     (unlike REST API v1).
#
# Security implications:
#   - Lambda permissions use source_arn scoped to this specific API's execution
#     ARN, not a wildcard. This prevents any other API Gateway from invoking
#     our functions even if it somehow had the function name.
#   - JWT authorizer is added in the Cognito module (Phase 1 Friday sprint) —
#     routes are unauthenticated here as an intentional stepping stone.

locals {
  name = "${var.app_name}-${var.environment}-api"
}

# --- API Gateway HTTP API ---
resource "aws_apigatewayv2_api" "this" {
  name          = local.name
  protocol_type = "HTTP"
  description   = "BBQ ranking platform HTTP API (${var.environment})"

  # CORS pre-flight support — origins tightened to CloudFront domain in Phase 3.
  # allow_methods and allow_headers cover all routes planned through Phase 2.
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PUT", "OPTIONS"]
    allow_headers = ["Authorization", "Content-Type"]
    max_age       = 300
  }
}

# --- CloudWatch log group for API access logs ---
# Pre-created so retention is set before the first request.
resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = var.log_retention_days
}

# --- Default stage ---
# $default stage is the standard for HTTP APIs — it's the catch-all stage
# that maps to the root URL. auto_deploy means route changes take effect
# immediately without a manual deployment step.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    # JSON structured format — fields align with our log standard (level, requestId, etc.)
    format = jsonencode({
      requestId        = "$context.requestId"
      sourceIp         = "$context.identity.sourceIp"
      routeKey         = "$context.routeKey"
      httpMethod       = "$context.httpMethod"
      status           = "$context.status"
      responseLength   = "$context.responseLength"
      integrationError = "$context.integrationErrorMessage"
    })
  }
}

# --- Lambda integrations (one per route) ---
# AWS_PROXY passes the full HTTP request to Lambda and returns its response
# unchanged. payload_format_version = "2.0" uses the v2 event format, which
# is simpler and what the health Lambda is written for.
resource "aws_apigatewayv2_integration" "lambda" {
  for_each = var.routes

  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = each.value.invoke_arn
  payload_format_version = "2.0"
}

# --- Routes (one per entry in var.routes) ---
# route_key format: "METHOD /path" matches the map keys.
resource "aws_apigatewayv2_route" "this" {
  for_each = var.routes

  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.lambda[each.key].id}"
}

# --- Lambda invoke permissions ---
# Grants API Gateway permission to invoke each Lambda function.
# source_arn is scoped to this API's execution ARN + any stage + any route,
# not a wildcard "*" — prevents other APIs from invoking our functions.
resource "aws_lambda_permission" "apigw" {
  for_each = var.routes

  # statement_id must be alphanumeric, underscores, or dashes.
  # Route key format "GET /v1/health" has spaces and slashes — strip both.
  statement_id  = "AllowAPIGW-${replace(replace(each.key, " ", "-"), "/", "-")}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
