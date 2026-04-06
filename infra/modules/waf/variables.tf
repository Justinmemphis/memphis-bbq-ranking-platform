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

variable "api_gateway_stage_arn" {
  description = <<-EOT
    ARN of the API Gateway $default stage to associate with the WAF WebACL.
    Output by the api_http module as 'stage_arn'.
    When null, the WebACL is created but not associated with any API stage
    (useful during initial scaffolding before the API module is wired up).
    Format: arn:aws:apigateway:{region}::/apis/{api-id}/stages/{stage-name}
  EOT
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch log retention for WAF sampled request logs. Dev: 14 days, prod: 90 days."
  type        = number
  default     = 14
}
