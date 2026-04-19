output "user_pool_id" {
  description = "Cognito User Pool ID — reference for admin operations and IAM policies"
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_client_id" {
  description = "App Client ID — used as the JWT audience in the API Gateway authorizer"
  value       = aws_cognito_user_pool_client.this.id
}

output "issuer_url" {
  description = <<-EOT
    JWT issuer URL for the API Gateway JWT authorizer.
    Format: https://cognito-idp.<region>.amazonaws.com/<user_pool_id>
    API Gateway validates the token's 'iss' claim against this value.
  EOT
  value       = "https://cognito-idp.us-east-1.amazonaws.com/${aws_cognito_user_pool.this.id}"
}

output "hosted_ui_base_url" {
  description = "Base URL for the Cognito Hosted UI (login page, token endpoint, etc.)"
  value       = "https://${var.domain_prefix}.auth.us-east-1.amazoncognito.com"
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN — used to scope IAM policies for admin Lambdas (e.g. AdminListGroupsForUser)"
  value       = aws_cognito_user_pool.this.arn
}
