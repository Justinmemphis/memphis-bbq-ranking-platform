variable "app_name" {
  description = "Application name prefix used in all resource names"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev or prod)"
  type        = string
}

variable "lambda_function_names" {
  description = "List of fully-qualified Lambda function names to monitor. Each gets its own Errors alarm."
  type        = list(string)
}

variable "api_gateway_id" {
  description = "API Gateway HTTP API ID (not ARN). Used as the ApiId dimension on CloudWatch metrics."
  type        = string
}

variable "notification_email" {
  description = "Email address to subscribe to the alarms SNS topic. Leave empty to skip creating a subscription (topic is still created). AWS sends a confirmation email — subscription is pending until confirmed."
  type        = string
  default     = ""
}
