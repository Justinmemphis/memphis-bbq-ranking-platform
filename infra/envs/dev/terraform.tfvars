app_name    = "bbq"
environment = "dev"
region      = "us-east-1"

# Cognito Hosted UI domain prefix — must be globally unique across all AWS accounts.
# If 'bbq-ranking-dev' is taken, change to 'bbq-ranking-dev-<suffix>' and re-apply.
cognito_domain_prefix = "bbq-ranking-dev"

# Email address for CloudWatch alarm notifications.
# Leave as empty string to skip email subscription (SNS topic still created).
# After apply, AWS sends a confirmation email — you must click the link to activate.
alarm_notification_email = ""
