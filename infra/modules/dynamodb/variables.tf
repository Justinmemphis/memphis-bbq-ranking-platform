variable "app_name" {
  description = "Application name prefix used in resource names"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev or prod)"
  type        = string
}
