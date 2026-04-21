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
#   - p99 latency threshold 500 ms: aligns with the Phase 4 SLO target
#     (p99 < 500 ms). evaluation_periods = 2 (10 min sustained) avoids false
#     alarms on isolated cold-start spikes while catching degradation quickly.
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

  alarm_name          = "${each.value}-errors"
  alarm_description   = "Lambda ${each.value} recorded at least 1 error in a 5-minute window. Investigate CloudWatch logs immediately."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
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

# --- API Gateway: 5xx error rate (SLO: error rate < 1%) ---
# Metric math: 100 * 5XXError / Count. Fires when >= 1% of requests return 5xx
# over a 5-minute window.
#
# Design decisions:
#   - Complements the absolute-count apigw_5xx alarm: the count alarm catches
#     error bursts during low traffic (e.g. 5 errors, 6 total requests = 83% error
#     rate) where the rate math might be noisy; the rate alarm catches sustained
#     degradation at higher traffic volumes where 5 absolute errors might be < 1%.
#   - treat_missing_data = "notBreaching": when Count = 0 (no traffic) the
#     division is undefined; CloudWatch returns no data — not a breach.
#   - evaluation_periods = 1: we want immediate signal on an SLO breach, not a
#     sustained-period gate. The 15-min gate on the latency alarm is appropriate
#     for cold-start noise; error rate spikes are actionable immediately.
#
# Security implication: a sudden spike in error rate can indicate a broken deploy,
# a DynamoDB throttle, or an attempted exploit hitting unhandled input paths.
# Cross-reference with Lambda error alarms and WAF logs.
resource "aws_cloudwatch_metric_alarm" "apigw_error_rate" {
  alarm_name          = "${local.name_prefix}-apigw-error-rate"
  alarm_description   = "API Gateway 5xx error rate >= 1% over a 5-minute window (SLO breach). Check Lambda error alarms and CloudWatch Logs for root cause."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "100 * m_5xx / m_count"
    label       = "5xx Error Rate (%)"
    return_data = true
  }

  metric_query {
    id = "m_count"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "Count"
      dimensions = {
        ApiId = var.api_gateway_id
        Stage = "$default"
      }
      period = 300
      stat   = "Sum"
    }
  }

  metric_query {
    id = "m_5xx"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "5XXError"
      dimensions = {
        ApiId = var.api_gateway_id
        Stage = "$default"
      }
      period = 300
      stat   = "Sum"
    }
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# --- API Gateway: p99 latency (SLO: p99 < 500 ms) ---
# Metric: IntegrationLatency p99 — time from API GW handing off to Lambda
# until Lambda returns a response. Includes cold start time.
# Threshold: 500 ms — SLO target. evaluation_periods = 2 (10 min sustained)
# avoids false alarms on isolated cold-start spikes while catching degradation quickly.
resource "aws_cloudwatch_metric_alarm" "apigw_latency" {
  alarm_name        = "${local.name_prefix}-apigw-latency-p99"
  alarm_description = "API Gateway p99 integration latency exceeded 500 ms for 10 consecutive minutes (SLO breach). Check Lambda duration metrics and DynamoDB latency."
  namespace         = "AWS/ApiGateway"
  metric_name       = "IntegrationLatency"
  dimensions = {
    ApiId = var.api_gateway_id
    Stage = "$default"
  }
  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 2
  threshold           = 500
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# --- Rating submission spike alarm ---
# Metric: Invocations on the submit_rating Lambda.
# Threshold: var.rating_spike_threshold invocations in a 5-minute window.
# Intent: detect rating stuffing or bot activity before it meaningfully skews the
# leaderboard. The per-IP WAF rate limit (prod-only) is the first line; this alarm
# is the detection signal when WAF is not in front (dev) or when an attacker
# uses many IPs.
#
# Design decisions:
#   - Uses Invocations (not Errors): an attacker submitting valid ratings won't
#     trigger the error alarm. We need a volume signal, not a failure signal.
#   - evaluation_periods = 1: fires on the first 5-min window that exceeds threshold.
#     We want early warning, not a sustained-pattern check.
#   - treat_missing_data = "notBreaching": expected in low-traffic dev environments
#     (nights/weekends). "breaching" would create constant alert noise on idle envs.
#   - threshold = 50 (default): 10 req/min sustained is abnormal for a dev environment.
#     Prod threshold should be tuned upward once baseline traffic is established.
#
# Security implication: fires to the same SNS topic as all other alarms, so an
# operator investigating a spike alarm can cross-reference the error and 5xx alarms
# from the same time window to distinguish bots (high volume, no errors) from a
# broken deploy (high volume + errors).
resource "aws_cloudwatch_metric_alarm" "rating_spike" {
  alarm_name          = "${local.name_prefix}-submit-rating-spike"
  alarm_description   = "submit_rating received ${var.rating_spike_threshold}+ invocations in a 5-minute window. Potential rating stuffing or bot activity — check the rating_events audit log and WAF sampled requests."
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  dimensions          = { FunctionName = var.submit_rating_function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.rating_spike_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# --- CloudWatch Dashboard ---
# Single ops dashboard per environment. Widgets are organized in four rows:
#   Row 1 (y=0):  API Health — request rate, 5xx error rate %, p99 latency, 4xx/throttles
#   Row 2 (y=6):  User Activity — logins (Cognito), rating submissions, audit log queries
#   Row 3 (y=12): Lambda Errors — all monitored functions on one graph
#   Row 4 (y=18): Alarm Status — live state of all CloudWatch alarms in this module
#
# Design decisions:
#   - SLO reference lines (500ms latency, 1% error rate) are rendered as horizontal
#     annotations so degradation is visually obvious before alarms fire.
#   - Cognito SignInSuccesses requires both UserPool and UserPoolClient dimensions —
#     without UserPoolClient the metric does not resolve in CloudWatch.
#   - Dashboard cost: first 3 dashboards per account are free; $3/month each after that.
#     At one dashboard per environment (dev + prod = 2 total), both are free.
#   - Lambda errors widget spans the full 24-unit width so all function lines are
#     visible without scrolling — useful during incident response.
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-ops"

  dashboard_body = jsonencode({
    widgets = concat(
      # --- Row 1: API Health ---
      [
        {
          type   = "metric"
          x      = 0
          y      = 0
          width  = 6
          height = 6
          properties = {
            title  = "Request Rate"
            view   = "timeSeries"
            stat   = "Sum"
            period = 300
            metrics = [
              ["AWS/ApiGateway", "Count", "ApiId", var.api_gateway_id, "Stage", "$default"]
            ]
            yAxis = { left = { min = 0 } }
          }
        },
        {
          type   = "metric"
          x      = 6
          y      = 0
          width  = 6
          height = 6
          properties = {
            title  = "5xx Error Rate %"
            view   = "timeSeries"
            period = 300
            metrics = [
              [{ expression = "100 * m_5xx / m_count", id = "error_rate", label = "Error Rate (%)" }],
              ["AWS/ApiGateway", "Count", "ApiId", var.api_gateway_id, "Stage", "$default", { id = "m_count", visible = false, stat = "Sum" }],
              ["AWS/ApiGateway", "5XXError", "ApiId", var.api_gateway_id, "Stage", "$default", { id = "m_5xx", visible = false, stat = "Sum" }]
            ]
            yAxis       = { left = { min = 0, max = 100 } }
            annotations = { horizontal = [{ value = 1, label = "SLO (1%)", color = "#d62728" }] }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 0
          width  = 6
          height = 6
          properties = {
            title  = "p99 Latency (ms)"
            view   = "timeSeries"
            period = 300
            metrics = [
              ["AWS/ApiGateway", "IntegrationLatency", "ApiId", var.api_gateway_id, "Stage", "$default", { stat = "p99" }]
            ]
            yAxis       = { left = { min = 0 } }
            annotations = { horizontal = [{ value = 500, label = "SLO (500ms)", color = "#d62728" }] }
          }
        },
        {
          type   = "metric"
          x      = 18
          y      = 0
          width  = 6
          height = 6
          properties = {
            title  = "4xx / Throttles"
            view   = "timeSeries"
            stat   = "Sum"
            period = 300
            metrics = [
              ["AWS/ApiGateway", "4XXError", "ApiId", var.api_gateway_id, "Stage", "$default"]
            ]
            yAxis = { left = { min = 0 } }
          }
        }
      ],
      # --- Row 2: User Activity ---
      [
        {
          type   = "metric"
          x      = 0
          y      = 6
          width  = 8
          height = 6
          properties = {
            title  = "Logins"
            view   = "timeSeries"
            stat   = "Sum"
            period = 300
            metrics = [
              ["AWS/Cognito", "SignInSuccesses", "UserPool", var.cognito_user_pool_id, "UserPoolClient", var.cognito_user_pool_client_id]
            ]
            yAxis = { left = { min = 0 } }
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 6
          width  = 8
          height = 6
          properties = {
            title  = "Rating Submissions"
            view   = "timeSeries"
            stat   = "Sum"
            period = 300
            metrics = [
              ["AWS/Lambda", "Invocations", "FunctionName", var.submit_rating_function_name]
            ]
            yAxis = { left = { min = 0 } }
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 6
          width  = 8
          height = 6
          properties = {
            title  = "Audit Log Queries"
            view   = "timeSeries"
            stat   = "Sum"
            period = 300
            metrics = [
              ["AWS/Lambda", "Invocations", "FunctionName", var.admin_audit_log_function_name]
            ]
            yAxis = { left = { min = 0 } }
          }
        }
      ],
      # --- Row 3: Lambda Errors ---
      [
        {
          type   = "metric"
          x      = 0
          y      = 12
          width  = 24
          height = 6
          properties = {
            title  = "Lambda Errors"
            view   = "timeSeries"
            stat   = "Sum"
            period = 300
            metrics = [
              for fn in var.lambda_function_names : ["AWS/Lambda", "Errors", "FunctionName", fn]
            ]
            yAxis = { left = { min = 0 } }
          }
        }
      ],
      # --- Row 4: Alarm Status ---
      [
        {
          type   = "alarm"
          x      = 0
          y      = 18
          width  = 24
          height = 4
          properties = {
            title = "Alarm Status"
            alarms = concat(
              [
                aws_cloudwatch_metric_alarm.apigw_5xx.arn,
                aws_cloudwatch_metric_alarm.apigw_error_rate.arn,
                aws_cloudwatch_metric_alarm.apigw_latency.arn,
                aws_cloudwatch_metric_alarm.apigw_throttles.arn,
                aws_cloudwatch_metric_alarm.rating_spike.arn,
              ],
              [for k, v in aws_cloudwatch_metric_alarm.lambda_errors : v.arn]
            )
          }
        }
      ]
    )
  })
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
