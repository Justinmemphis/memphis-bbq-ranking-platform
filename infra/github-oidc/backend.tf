# Account-level resources — separate state from dev/prod environments.
# The GitHub OIDC provider and IAM role are not environment-specific;
# they exist once per AWS account.

terraform {
  backend "s3" {
    bucket         = "bbq-tfstate-justin"
    key            = "github-oidc/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "bbq-tfstate-lock"
    encrypt        = true
  }
}
