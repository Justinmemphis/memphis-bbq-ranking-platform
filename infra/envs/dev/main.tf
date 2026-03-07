terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.app_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Module calls will be added here as each module is implemented.
# Example pattern:
#   module "dynamodb" {
#     source      = "../../modules/dynamodb"
#     app_name    = var.app_name
#     environment = var.environment
#   }
