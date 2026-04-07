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

variable "create_additional_policy" {
  description = <<-EOT
    Set to true when additional_policy_json is provided. Controls whether the
    inline IAM policy resource is created. Must be a static literal (true/false)
    at the call site — cannot be derived from computed values such as resource ARNs,
    because Terraform evaluates count at plan time before any resources exist.
  EOT
  type        = bool
  default     = false
}

variable "additional_policy_json" {
  description = <<-EOT
    Optional JSON IAM policy document to attach to the Lambda execution role as an
    inline policy. Use this to grant per-function permissions (e.g. DynamoDB access)
    without embedding them in the module itself — keeps the module generic and
    each function's permissions explicit at the call site.

    Must be a valid IAM policy JSON string (use jsonencode() in the caller).
    Leave empty (default) when no additional permissions are needed.

    Security note: follow least privilege — scope each statement to the specific
    table ARN and action set the function actually needs.
  EOT
  type        = string
  default     = ""
}
