variable "app_name" {
  description = "Application name prefix used in all resource names"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev or prod)"
  type        = string
}

variable "routes" {
  description = <<-EOT
    Map of route keys to Lambda integration targets.
    Key format: "METHOD /path" (e.g., "GET /v1/health").
    Each value must supply the Lambda invoke_arn (for the integration)
    and function_name (to grant the API Gateway invoke permission).
  EOT
  type = map(object({
    invoke_arn    = string
    function_name = string
  }))
}

variable "log_retention_days" {
  description = "CloudWatch log retention for API Gateway access logs"
  type        = number
  default     = 14
}

variable "jwt_authorizer" {
  description = <<-EOT
    Optional JWT authorizer configuration. When set, all routes require a valid JWT.
    issuer:   the token issuer URL (e.g., Cognito User Pool endpoint).
              API Gateway validates the 'iss' claim against this value.
    audience: list of accepted audiences (e.g., [cognito_app_client_id]).
              API Gateway validates the 'aud' claim against this list.
    When null, routes are unauthenticated (used during initial scaffolding only).
  EOT
  type = object({
    issuer   = string
    audience = list(string)
  })
  default = null
}
