output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name (e.g. d1234abcd.cloudfront.net). Empty string when enable_cloudfront = false."
  value       = var.enable_cloudfront ? aws_cloudfront_distribution.static[0].domain_name : ""
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID. Empty string when enable_cloudfront = false."
  value       = var.enable_cloudfront ? aws_cloudfront_distribution.static[0].id : ""
}

output "cloudfront_distribution_arn" {
  description = "CloudFront distribution ARN. Used in Sprint 22 to associate WAF WebACL (CLOUDFRONT scope). Empty string when enable_cloudfront = false."
  value       = var.enable_cloudfront ? aws_cloudfront_distribution.static[0].arn : ""
}

output "s3_bucket_name" {
  description = "Static site S3 bucket name. Empty string when enable_cloudfront = false."
  value       = var.enable_cloudfront ? aws_s3_bucket.static[0].bucket : ""
}

output "s3_bucket_arn" {
  description = "Static site S3 bucket ARN. Empty string when enable_cloudfront = false."
  value       = var.enable_cloudfront ? aws_s3_bucket.static[0].arn : ""
}
