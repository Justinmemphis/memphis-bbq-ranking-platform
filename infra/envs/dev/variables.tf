variable "app_name" {
  description = "Application name prefix used in all resource names"
  type        = string
  default     = "bbq"
}

variable "environment" {
  description = "Deployment environment (dev or prod)"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "cognito_domain_prefix" {
  description = <<-EOT
    Cognito Hosted UI subdomain prefix (globally unique across all AWS accounts).
    Change this in terraform.tfvars if the prefix is already taken.
  EOT
  type        = string
}

variable "alarm_notification_email" {
  description = "Email address to receive CloudWatch alarm notifications. Leave empty to skip email subscription (SNS topic is still created). AWS sends a confirmation email — you must click the link to activate."
  type        = string
  default     = ""
}

variable "enable_waf" {
  description = "Whether to create the WAF WebACL. Dev is always false — WAF costs ~$5/month regardless of traffic."
  type        = bool
  default     = false
}

variable "enable_cloudfront" {
  description = "Whether to create the S3 static site bucket and CloudFront distribution. Enabled in both dev and prod — no fixed monthly fee, so cost does not justify an environment gap."
  type        = bool
  default     = true
}

variable "google_maps_api_key" {
  description = <<-EOT
    Google Maps Embed API key for the public frontend. Maps Embed API is $0/load.
    NOT set here — pass via environment variable to keep the key out of git:
      export TF_VAR_google_maps_api_key="AIza..."
    Key must be restricted to HTTP referrers (CloudFront domain) and scoped to
    the Maps Embed API only in the Google Cloud Console.
  EOT
  type      = string
  default   = ""
  sensitive = true
}
