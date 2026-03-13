variable "app_name" {
  description = "Application name prefix used in all resource names"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev or prod)"
  type        = string
}

variable "domain_prefix" {
  description = <<-EOT
    Cognito Hosted UI subdomain prefix (must be globally unique across all AWS accounts).
    Resolves to: https://<domain_prefix>.auth.us-east-1.amazoncognito.com
    Convention: <app>-<env>-<short-unique-suffix> — e.g., bbq-ranking-dev.
    If the prefix is taken, change it in terraform.tfvars (no data model impact).
  EOT
  type        = string
}

variable "callback_urls" {
  description = "OAuth callback URLs registered on the app client (used by Hosted UI after sign-in)"
  type        = list(string)
  default     = ["http://localhost", "http://localhost:3000/callback"]
}

variable "logout_urls" {
  description = "OAuth logout URLs registered on the app client"
  type        = list(string)
  default     = ["http://localhost", "http://localhost:3000"]
}
