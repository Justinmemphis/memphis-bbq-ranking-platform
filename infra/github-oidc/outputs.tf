# Add this role ARN as a GitHub Actions secret named AWS_OIDC_ROLE_ARN
# Settings → Secrets and variables → Actions → New repository secret
output "github_actions_role_arn" {
  description = "ARN of the IAM role assumed by GitHub Actions via OIDC"
  value       = aws_iam_role.github_actions.arn
}
