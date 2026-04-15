app_name    = "bbq"
environment = "prod"
region      = "us-east-1"

# Cognito Hosted UI domain prefix — must be globally unique across all AWS accounts.
# If 'bbq-ranking-prod' is taken, change to 'bbq-ranking-prod-<suffix>' and re-apply.
cognito_domain_prefix = "bbq-ranking-prod"

# WAF is enabled for prod — WebACL protects the API Gateway stage.
enable_waf = true

# CloudFront is enabled for prod — serves the static site; required for WAF CLOUDFRONT scope (Sprint 22).
enable_cloudfront = true

# Email address for CloudWatch alarm notifications.
# NOT set here — pass via environment variable to keep your email out of git:
#   export TF_VAR_alarm_notification_email="your@email.com"
# Leave the variable unset (or export as empty string) to skip email subscription;
# the SNS topic is still created and alarms still fire — just no email delivery.
