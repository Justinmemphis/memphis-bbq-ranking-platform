# WAF WebACL — prod-only edge protection for the API Gateway HTTP API.
#
# Why prod-only: AWS WAF WebACL costs ~$5/month in base fees regardless of traffic.
# Dev runs without WAF intentionally — that tradeoff is documented in terraform.tfvars.
#
# Scope = REGIONAL: attaches to API Gateway, ALBs, and AppSync.
# CLOUDFRONT scope requires a separate us-east-1 provider and is used for CloudFront
# distributions only — not needed here since the API is accessed directly.
#
# Rules are added in Sprint 15 (managed rule groups + rate limit).
# This sprint establishes the module skeleton and verifies the count pattern works.
#
# Security implication: the default_action is `allow`. With no rules yet, WAF passes
# all traffic through. Adding rules in Sprint 15 will block known-bad inputs and
# rate-limit abusive IPs before any of that traffic reaches API Gateway.

resource "aws_wafv2_web_acl" "main" {
  # count = 0 means Terraform creates no WAF resources for dev.
  # count = 1 means Terraform creates the WebACL for prod.
  count = var.enable_waf ? 1 : 0

  name  = "${var.app_name}-${var.environment}-webacl"
  scope = "REGIONAL"

  # Default: allow traffic unless a rule explicitly blocks it.
  # This is the correct default — rules added in Sprint 15 define what to block.
  # Alternative considered: default block + allowlist. Rejected: too brittle for
  # an API that receives arbitrary JWT-authenticated requests from a web UI.
  default_action {
    allow {}
  }

  # visibility_config is required by the AWS provider even when there are no rules.
  # sampled_requests_enabled = true lets you inspect a sample of evaluated requests
  # in the AWS console — useful for tuning rules and debugging false positives.
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.app_name}-${var.environment}-webacl"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.app_name}-${var.environment}-webacl"
  }
}
