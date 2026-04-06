output "api_endpoint" {
  description = "Base URL for the API (e.g., https://<id>.execute-api.us-east-1.amazonaws.com)"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "api_id" {
  description = "API Gateway HTTP API ID (used to scope JWT authorizer in the Cognito module)"
  value       = aws_apigatewayv2_api.this.id
}

output "stage_arn" {
  description = "ARN of the $default stage — passed to the WAF module to associate the WebACL with this API."
  value       = aws_apigatewayv2_stage.default.arn
}
