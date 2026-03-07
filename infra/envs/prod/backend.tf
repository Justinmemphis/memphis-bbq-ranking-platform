# Remote state backend for the prod environment.
# Uses the same S3 bucket as dev but a separate state key.
# Replace the placeholder values below with your actual resource names.

terraform {
  backend "s3" {
    bucket         = "bbq-tfstate-justin"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "bbq-tfstate-lock"
    encrypt        = true
  }
}
