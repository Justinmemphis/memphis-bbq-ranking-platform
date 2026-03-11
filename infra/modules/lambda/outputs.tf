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
