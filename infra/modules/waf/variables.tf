variable "app_name" {
  description = "Application name prefix used in all resource names"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev or prod)"
  type        = string
}

variable "enable_waf" {
  description = <<-EOT
    Whether to create the WAF WebACL.
    Set to true for prod only — WebACL costs ~$5/month regardless of traffic,
    so dev intentionally runs without WAF protection.
  EOT
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "CloudWatch log retention for WAF sampled request logs. Dev: 14 days, prod: 90 days."
  type        = number
  default     = 14
}
