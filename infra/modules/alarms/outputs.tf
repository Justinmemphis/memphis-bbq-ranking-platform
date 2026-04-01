output "sns_topic_arn" {
  description = "ARN of the SNS alarms topic — use to wire additional alarms or subscriptions outside this module"
  value       = aws_sns_topic.alarms.arn
}
