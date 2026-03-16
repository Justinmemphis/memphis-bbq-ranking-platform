output "function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.this.arn
}

output "function_name" {
  description = "Name of the Lambda function (used to grant API Gateway invoke permission)"
  value       = aws_lambda_function.this.function_name
}

output "invoke_arn" {
  description = "ARN used by API Gateway to invoke this function (different from function ARN)"
  value       = aws_lambda_function.this.invoke_arn
}

output "role_name" {
  description = "Name of the Lambda execution IAM role — use this to attach additional inline policies at the call site"
  value       = aws_iam_role.lambda.name
}
