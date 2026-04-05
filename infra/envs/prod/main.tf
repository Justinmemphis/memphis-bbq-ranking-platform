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

# --- WAF WebACL ---
# Prod has enable_waf = true (set in terraform.tfvars).
# WebACL is REGIONAL scope — attaches to API Gateway.
# Managed rules and rate limit rule are added in Sprint 15.
# Association with the API Gateway stage is also wired in Sprint 15.
module "waf" {
  source      = "../../modules/waf"
  app_name    = var.app_name
  environment = var.environment
  enable_waf  = var.enable_waf
}
