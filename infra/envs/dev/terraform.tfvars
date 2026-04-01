app_name    = "bbq"
environment = "dev"
region      = "us-east-1"

# Cognito Hosted UI domain prefix — must be globally unique across all AWS accounts.
# If 'bbq-ranking-dev' is taken, change to 'bbq-ranking-dev-<suffix>' and re-apply.
cognito_domain_prefix = "bbq-ranking-dev"

# Email address for CloudWatch alarm notifications.
# NOT set here — pass via environment variable to keep your email out of git:
#   export TF_VAR_alarm_notification_email="your@email.com"
# Leave the variable unset (or export as empty string) to skip email subscription;
# the SNS topic is still created and alarms still fire — just no email delivery.
alarm_notification_email = ""
