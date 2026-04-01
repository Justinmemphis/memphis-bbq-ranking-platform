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
