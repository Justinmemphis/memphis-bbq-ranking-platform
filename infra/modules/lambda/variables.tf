variable "app_name" {
  description = "Application name prefix used in all resource names"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev or prod)"
  type        = string
}

variable "function_name" {
  description = "Short function name; full resource name will be {app_name}-{environment}-{function_name}"
  type        = string
}

variable "handler" {
  description = "Lambda handler in module.function format"
  type        = string
  default     = "handler.handler"
}

variable "runtime" {
  description = "Lambda runtime identifier"
  type        = string
  default     = "python3.12"
}

variable "source_path" {
  description = "Absolute path to the Lambda source directory — zipped by Terraform at plan/apply time"
  type        = string
}

variable "environment_vars" {
  description = "Environment variables injected into the Lambda runtime"
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days — set low in dev to control cost"
  type        = number
  default     = 14
}
