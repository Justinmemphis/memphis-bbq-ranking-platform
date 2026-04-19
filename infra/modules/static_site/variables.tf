variable "app_name" {
  description = "Application name prefix used in all resource names"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev or prod)"
  type        = string
}

variable "enable_cloudfront" {
  description = "Whether to create the S3 bucket and CloudFront distribution. Set false in dev to avoid CloudFront costs (~$0 fixed but adds plan noise). Sprint 22 WAF association requires this to be true in prod."
  type        = bool
  default     = false
}

variable "web_acl_id" {
  description = "WAF WebACL ARN (CLOUDFRONT scope) to associate with the CloudFront distribution. Null when WAF is not enabled (dev). Passed from the waf module's web_acl_arn output."
  type        = string
  default     = null
}
