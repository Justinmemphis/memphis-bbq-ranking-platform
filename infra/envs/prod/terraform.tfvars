app_name    = "bbq"
environment = "prod"
region      = "us-east-1"

# WAF is enabled for prod — WebACL protects the API Gateway stage.
# Rules (managed rule groups + rate limit) are added in Sprint 15.
enable_waf = true
