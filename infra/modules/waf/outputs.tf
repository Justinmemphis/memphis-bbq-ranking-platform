output "web_acl_arn" {
  description = "WAF WebACL ARN — used in Sprint 15 to associate with the API Gateway stage. Null when enable_waf = false."
  value       = var.enable_waf ? aws_wafv2_web_acl.main[0].arn : null
}

output "web_acl_id" {
  description = "WAF WebACL ID. Null when enable_waf = false."
  value       = var.enable_waf ? aws_wafv2_web_acl.main[0].id : null
}
