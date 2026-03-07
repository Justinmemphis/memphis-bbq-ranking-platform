# Remote state backend for the dev environment.
# Before running `terraform init` you must create:
#   - an S3 bucket for state storage
#   - a DynamoDB table for state locking (billing mode: PAY_PER_REQUEST, hash key: LockID)
# Replace the placeholder values below with your actual resource names.

terraform {
  backend "s3" {
    bucket         = "REPLACE-WITH-YOUR-TFSTATE-BUCKET"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "REPLACE-WITH-YOUR-TFSTATE-LOCK-TABLE"
    encrypt        = true
  }
}
