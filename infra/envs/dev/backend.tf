# Remote state backend for the dev environment.
# Before running `terraform init` you must create:
#   - an S3 bucket for state storage
#   - a DynamoDB table for state locking (billing mode: PAY_PER_REQUEST, hash key: LockID)
# Replace the placeholder values below with your actual resource names.

terraform {
  backend "s3" {
    bucket         = "bbq-tfstate-justin"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "bbq-tfstate-lock"
    encrypt        = true
  }
}
