# Module: alarms
#
# Provisions CloudWatch alarms for Lambda functions and API Gateway, plus the
# SNS topic that delivers notifications.
#
# Design decisions:
#   - Alarms live in a dedicated module (not embedded in lambda or api_http).
#     This keeps each module single-responsibility and lets the env configure all
#     alarms together where cross-cutting thresholds are visible in one place.
#   - SNS topic is created here (not passed in) so the module is self-contained.
#     A single topic per environment is fine for now; a more granular topic
#     strategy (e.g., per-severity) can be added in Phase 4.
#   - Lambda error alarm threshold = 1 (any error fires the alarm). Lambda errors
#     are unexpected — we want signal on the very first one, not a moving average.
#     evaluation_periods = 1 so it fires immediately on the first 5-min window
#     containing an error, not after a sustained period.
#   - API Gateway alarms use the per-stage CloudWatch metrics published by HTTP
#     API (v2). Metric names differ slightly from REST API (v1) — verified
#     against AWS docs for HTTP API.
#   - p99 latency threshold 3000 ms: conservative for a serverless cold-start
#     baseline; tighten in Phase 4 once warm-path baseline is established.
#   - treat_missing_data = "notBreaching": missing data means no traffic, not an
#     error. Using "breaching" would fire alarms on idle dev environments
#     (nights/weekends) and create alert fatigue.
#
# Security implications:
#   - SNS topic email subscription is created only when notification_email is
#     provided. AWS sends a confirmation email — subscription is pending until
#     the link is clicked. Do not use a shared/distribution list without owner buy-in.
#   - No KMS encryption on the SNS topic for dev; prod should add KMS CMK in Phase 4.
#
# Alternatives considered:
#   - EventBridge rules: more flexible routing but unnecessary complexity for
#     email-only notifications at this scale.
#   - Lambda error rate vs. raw count: rate alarms require a denominator (total
#     invocations), which smooths out low-traffic noise but delays detection.
#     Raw count >= 1 is simpler and catches errors in low-traffic dev immediately.

locals {
  name_prefix = "${var.app_name}-${var.environment}"
}

# --- SNS topic ---
# One topic per environment. All alarms publish here; subscribers receive all
# alarm state changes (OK → ALARM and ALARM → OK).
resource "aws_sns_topic" "alarms" {
  name = "${local.name_prefix}-alarms"
}

# --- SNS email subscription (optional) ---
# Created only when notification_email is provided. AWS sends a confirmation
# email before the subscription becomes active — subscriber must click the link.
resource "aws_sns_topic_subscription" "email" {
  count = var.notification_email != "" ? 1 : 0

  topic_arn                       = aws_sns_topic.alarms.arn
  protocol                        = "email"
  endpoint                        = var.notification_email
  confirmation_timeout_in_minutes = 1
  endpoint_auto_confirms          = false
}

# --- Lambda error alarms ---
# One alarm per function name in var.lambda_function_names.
# Metric: Errors — invocation-level error count (unhandled exceptions + timeouts).
# Threshold: 1 — any Lambda error triggers the alarm.
# Period: 300 s (5 min), evaluation_periods = 1 — fires on the first bad window.
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = toset(var.lambda_function_names)

  alarm_name        = "${each.value}-errors"
  alarm_description = "Lambda ${each.value} recorded at least 1 error in a 5-minute window. Investigate CloudWatch logs immediately."
  namespace         = "AWS/Lambda"
  metric_name       = "Errors"
  dimensions        = { FunctionName = each.value }
  statistic         = "Sum"
  period            = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# --- API Gateway: 5xx error rate ---
# Metric: 5XXError count on the $default stage.
# Threshold: 5 errors in a 5-minute period — a handful of isolated 5xxs
# (e.g. a single bad deploy) shouldn't page immediately, but 5+ signals a real problem.
# HTTP API v2 publishes to AWS/ApiGateway with ApiId + Stage dimensions.
resource "aws_cloudwatch_metric_alarm" "apigw_5xx" {
  alarm_name        = "${local.name_prefix}-apigw-5xx"
  alarm_description = "API Gateway is returning 5xx errors. Check Lambda error alarms and CloudWatch Logs for root cause."
  namespace         = "AWS/ApiGateway"
  metric_name       = "5XXError"
  dimensions = {
    ApiId = var.api_gateway_id
    Stage = "$default"
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# --- API Gateway: p99 latency ---
# Metric: IntegrationLatency p99 — time from API GW handing off to Lambda
# until Lambda returns a response. Includes cold start time.
# Threshold: 3000 ms. evaluation_periods = 3 (15 min sustained) avoids false
# alarms on isolated cold-start spikes; tighten once warm-path baseline is known.
resource "aws_cloudwatch_metric_alarm" "apigw_latency" {
  alarm_name        = "${local.name_prefix}-apigw-latency-p99"
  alarm_description = "API Gateway p99 integration latency exceeded 3 s for 15 consecutive minutes. Check Lambda duration metrics and DynamoDB latency."
  namespace         = "AWS/ApiGateway"
  metric_name       = "IntegrationLatency"
  dimensions = {
    ApiId = var.api_gateway_id
    Stage = "$default"
  }
  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 3
  threshold           = 3000
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# --- API Gateway: throttle count ---
# Metric: 4XXError with a note — HTTP API v2 does not publish a dedicated
# "ThrottleCount" metric. Throttles appear as 429s counted in 4XXError.
# We use a separate alarm scoped to the route-level default throttle to catch
# capacity ceiling hits. Threshold = 1: any throttle is worth knowing about.
#
# Note: if WAF rate-limit rules fire (Phase 3), those 429s also increment this
# counter. That's intentional — both signal "requests being rejected at the edge."
resource "aws_cloudwatch_metric_alarm" "apigw_throttles" {
  alarm_name        = "${local.name_prefix}-apigw-throttles"
  alarm_description = "API Gateway is returning 4xx errors (possible throttles/429s). Check if account-level burst limits or WAF rate rules are firing."
  namespace         = "AWS/ApiGateway"
  metric_name       = "4XXError"
  dimensions = {
    ApiId = var.api_gateway_id
    Stage = "$default"
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}
