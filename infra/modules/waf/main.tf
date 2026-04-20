# WAF WebACL — prod-only edge protection.
#
# Why prod-only: AWS WAF WebACL costs ~$5/month in base fees regardless of traffic.
# Dev runs without WAF intentionally — that tradeoff is documented in terraform.tfvars.
#
# Scope = CLOUDFRONT: CloudFront distributions require CLOUDFRONT-scoped WebACLs.
# HTTP API (API Gateway v2) cannot use aws_wafv2_web_acl_association — only REST API
# (v1) stages are supported by that resource. CloudFront is the correct association point.
# The WebACL must be deployed in us-east-1 for CLOUDFRONT scope (already our region).
#
# Association: the web_acl_arn output is passed to the static_site module, which sets
# web_acl_id on the aws_cloudfront_distribution resource. No separate association resource
# is needed — CloudFront reads the web_acl_id directly from its distribution config.
#
# Security design: default_action = allow. Rules define what to BLOCK.
# Alternative (default block + allowlist) was rejected: too brittle for an API that
# receives arbitrary JWT-authenticated requests from a browser-based client.

resource "aws_wafv2_web_acl" "main" {
  count = var.enable_waf ? 1 : 0

  name  = "${var.app_name}-${var.environment}-webacl"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # --- Rule 1: Per-IP rate limit ---
  # Blocks IPs that exceed 1000 requests per 5-minute window.
  #
  # Threat addressed: rating stuffing and bot-driven submission floods.
  # 1000 req/5min ≈ 3.3 req/sec sustained — well above normal human browsing
  # (a user might submit 1–2 ratings per session) but low enough to catch
  # automated scripts hammering the API.
  #
  # Why rate-limit at priority 1 (evaluated first): IP flood traffic is cut off
  # before AWS charges for managed-rule evaluation compute on those requests.
  #
  # Limitation: IP-based only. Per-user (JWT sub) rate limiting requires
  # Lambda@Edge to inspect claims — that is deferred to Phase 4. Per-user
  # limits are also enforced at the application layer in submit_rating.
  rule {
    name     = "RateLimitPerIP"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.app_name}-${var.environment}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # --- Rule 2: AWS Managed Rules — CommonRuleSet ---
  # Provides broad protection against OWASP Top 10 categories: SQLi, XSS,
  # path traversal, RFI, LFI, HTTP anomalies, and oversized requests.
  #
  # Why this group: our /v1/ endpoints accept user-supplied text (ratings,
  # search queries). CommonRuleSet blocks the most widespread attack patterns
  # without requiring custom rule authoring and is maintained by AWS.
  #
  # override_action = none: use each rule's own action (BLOCK for HIGH severity,
  # COUNT for lower severity depending on the specific rule in the group).
  #
  # Sharp edge: SizeRestrictions_BODY blocks payloads > 8 KB. This is fine for
  # our rating submissions (small JSON) but watch sampled requests in the console
  # if a future endpoint accepts larger payloads. Override specific rules to COUNT
  # if confirmed false positives arise in prod.
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.app_name}-${var.environment}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # --- Rule 3: AWS Managed Rules — KnownBadInputsRuleSet ---
  # Blocks request patterns associated with Log4Shell (CVE-2021-44228),
  # Spring4Shell, and other known exploit delivery mechanisms.
  #
  # Why this group: Log4Shell payloads are injected via HTTP headers and body
  # fields — exactly the surface our API exposes. Even though our Python Lambda
  # functions do not use Log4j, API Gateway access logs and downstream systems
  # might. This rule resolves CKV_AWS_192 (WAF must block Log4j2 lookup patterns).
  #
  # Evaluated at priority 3 (after rate limit and CommonRuleSet) because it's
  # targeted and has minimal overlap with the broader CommonRuleSet.
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.app_name}-${var.environment}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # WebACL-level visibility — aggregates metrics for all rules combined.
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.app_name}-${var.environment}-webacl"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.app_name}-${var.environment}-webacl"
  }
}

# --- CloudWatch log group for WAF logs ---
# Name MUST start with 'aws-waf-logs-' — AWS WAF service requirement.
# WAF writes sampled request logs here (not all traffic — sampled per rule match).
# Retention set via variable: dev 14 days, prod 90 days.
resource "aws_cloudwatch_log_group" "waf" {
  count             = var.enable_waf ? 1 : 0
  name              = "aws-waf-logs-${var.app_name}-${var.environment}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "aws-waf-logs-${var.app_name}-${var.environment}"
  }
}

# --- Resource policy: allow WAF to write to the CloudWatch log group ---
# WAF uses the 'delivery.logs.amazonaws.com' service principal (not wafv2.amazonaws.com)
# to deliver logs. Without this policy, the logging configuration fails with a
# permissions error when WAF tries to create a log delivery.
#
# Resource = "*" is required by the AWS WAF service — it cannot be scoped to the
# specific log group ARN because WAF needs to create and manage the delivery stream
# internally. This is an AWS service limitation, not a design choice.
resource "aws_cloudwatch_log_resource_policy" "waf" {
  count       = var.enable_waf ? 1 : 0
  policy_name = "waf-${var.app_name}-${var.environment}"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action = [
          "logs:CreateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:GetLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutLogEvents",
          "logs:PutRetentionPolicy",
          "logs:UpdateLogDelivery",
        ]
        Resource = "*"
      },
    ]
  })
}

# --- WAF logging configuration ---
# Connects the WebACL to the CloudWatch log group.
# WAF writes sampled requests that match rules (blocks and allows-after-challenge).
# Resolves CKV2_AWS_31 (WAF2 logging configuration required).
#
# Note: depends_on the resource policy because WAF cannot create the log delivery
# until the policy granting delivery.logs.amazonaws.com access is in place.
resource "aws_wafv2_web_acl_logging_configuration" "main" {
  count                   = var.enable_waf ? 1 : 0
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]
  resource_arn            = aws_wafv2_web_acl.main[0].arn

  depends_on = [aws_cloudwatch_log_resource_policy.waf]
}

# --- WAF association ---
# Association is handled in the static_site module via CloudFront's web_acl_id attribute.
# This module exports web_acl_arn; the caller passes it to the static_site module.
# No aws_wafv2_web_acl_association resource is needed for CLOUDFRONT-scope WebACLs.
