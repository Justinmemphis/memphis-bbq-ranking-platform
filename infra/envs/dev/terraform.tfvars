app_name    = "bbq"
environment = "dev"
region      = "us-east-1"

# Cognito Hosted UI domain prefix — must be globally unique across all AWS accounts.
# If 'bbq-ranking-dev' is taken, change to 'bbq-ranking-dev-<suffix>' and re-apply.
cognito_domain_prefix = "bbq-ranking-dev"

# WAF is prod-only. Dev has no WebACL — saves ~$5/month in base fees.
enable_waf = false

# CloudFront is prod-only. Dev has no distribution — keeps the plan lean.
enable_cloudfront = false

# Email address for CloudWatch alarm notifications.
# NOT set here — pass via environment variable to keep your email out of git:
#   export TF_VAR_alarm_notification_email="your@email.com"
# Leave the variable unset (or export as empty string) to skip email subscription;
# the SNS topic is still created and alarms still fire — just no email delivery.
