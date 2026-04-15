# Module: static_site
#
# Provisions the frontend hosting stack:
#   - S3 bucket (private, public access blocked, versioning + AES-256 encryption)
#   - CloudFront Origin Access Control (OAC) — modern replacement for legacy OAI
#   - CloudFront distribution with S3 origin via OAC
#   - S3 bucket policy granting read access to CloudFront only
#
# Security model:
#   The S3 bucket has no public access. Objects are served exclusively through
#   CloudFront, which signs requests to S3 using OAC (sigv4). The bucket policy
#   restricts reads to the specific CloudFront distribution ARN — not all CF distributions.
#
# Why OAC over OAI:
#   OAC is the AWS-recommended approach as of 2022. OAI is legacy and doesn't support
#   SSE-S3 or SSE-KMS encrypted buckets. OAC uses SigV4 signing, which is more secure.
#
# Why default CloudFront certificate (not ACM):
#   No custom domain is configured for this portfolio project. The default
#   cloudfront.net certificate is sufficient. TLSv1.2_2021 requires a custom ACM cert —
#   deferred to Phase 5 if a custom domain is added.
#
# count pattern:
#   All resources use count = var.enable_cloudfront ? 1 : 0.
#   When false (dev), no resources are created and outputs return empty strings.

locals {
  bucket_name = "${var.app_name}-${var.environment}-static"
}

# --- S3 bucket ---
# Private bucket; no direct public access. All reads go through CloudFront.
resource "aws_s3_bucket" "static" {
  count  = var.enable_cloudfront ? 1 : 0
  bucket = local.bucket_name
}

# Block all public access — belt-and-suspenders with the bucket policy below.
# These four settings prevent ACL grants, bucket policies, and object URLs
# from ever exposing content publicly, regardless of other config.
resource "aws_s3_bucket_public_access_block" "static" {
  count  = var.enable_cloudfront ? 1 : 0
  bucket = aws_s3_bucket.static[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Disable ACLs entirely — BucketOwnerEnforced is the modern AWS default.
# OAC does not use ACLs; all access is controlled via bucket policy.
resource "aws_s3_bucket_ownership_controls" "static" {
  count  = var.enable_cloudfront ? 1 : 0
  bucket = aws_s3_bucket.static[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Versioning enables rollback of static deployments.
# If a bad index.html is deployed, the previous version can be restored.
resource "aws_s3_bucket_versioning" "static" {
  count  = var.enable_cloudfront ? 1 : 0
  bucket = aws_s3_bucket.static[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Server-side encryption with S3-managed keys (AES-256).
# Why not KMS: public static assets provide no confidentiality benefit from KMS CMKs,
# and KMS adds per-request API cost. AES-256 satisfies encryption-at-rest requirements
# for this workload. KMS would be appropriate if this bucket stored sensitive data.
#
# checkov skip CKV_AWS_145: S3 KMS CMK — AES-256 is sufficient for public static assets;
# KMS adds per-request cost without security benefit for non-sensitive content.
resource "aws_s3_bucket_server_side_encryption_configuration" "static" {
  count  = var.enable_cloudfront ? 1 : 0
  bucket = aws_s3_bucket.static[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- CloudFront Origin Access Control ---
# OAC instructs CloudFront to sign every S3 request with SigV4.
# The bucket policy below only accepts requests signed by this specific distribution.
# signing_behavior = "always": sign all requests, including those to custom origins.
# signing_protocol = "sigv4": the only supported protocol for S3 OAC.
resource "aws_cloudfront_origin_access_control" "static" {
  count = var.enable_cloudfront ? 1 : 0

  name                              = "${var.app_name}-${var.environment}-oac"
  description                       = "OAC for ${var.app_name}-${var.environment} static site S3 origin"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# --- CloudFront Distribution ---
# Serves the static site globally. HTTP requests are redirected to HTTPS.
# Origin: S3 bucket via OAC (no direct public access).
# Cache: AWS managed CachingOptimized policy — appropriate for immutable static assets.
# TLS: default CloudFront cert (cloudfront.net domain); TLSv1.2_2021 requires ACM cert.
#
# checkov skip CKV_AWS_68:  WAF not associated — WAF is wired to CloudFront in Sprint 22
#                           via CLOUDFRONT-scope WebACL.
# checkov skip CKV_AWS_86:  Access logging disabled — not required for portfolio project;
#                           CloudFront metrics via CloudWatch are sufficient.
# checkov skip CKV_AWS_174: TLS 1.2 minimum — default CloudFront cert restricts
#                           minimum_protocol_version to TLSv1; TLSv1.2_2021 requires a
#                           custom ACM cert. Deferred to Phase 5.
resource "aws_cloudfront_distribution" "static" {
  # checkov:skip=CKV_AWS_68:WAF association wired in Sprint 22 via CLOUDFRONT-scope WebACL
  # checkov:skip=CKV_AWS_86:Access logging not required for portfolio project
  # checkov:skip=CKV_AWS_174:Default CloudFront cert limits minimum_protocol_version to TLSv1; custom ACM cert needed for TLSv1.2_2021, deferred to Phase 5
  count   = var.enable_cloudfront ? 1 : 0
  enabled = true
  comment = "${var.app_name}-${var.environment} static site"

  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.static[0].bucket_regional_domain_name
    origin_id                = "s3-${local.bucket_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.static[0].id
  }

  default_cache_behavior {
    target_origin_id       = "s3-${local.bucket_name}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed CachingOptimized policy (ID is stable across all accounts/regions).
    # Caches GET/HEAD responses; uses Cache-Control and Expires headers from S3.
    # Appropriate for versioned static assets — max TTL 31,536,000s (1 year).
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # Default CloudFront certificate — no custom domain required for portfolio.
  # minimum_protocol_version is constrained to TLSv1 by AWS when using the
  # default certificate. TLSv1.2_2021 requires a custom ACM cert (Phase 5).
  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = "${var.app_name}-${var.environment}-distribution"
  }
}

# --- S3 Bucket Policy ---
# Grants CloudFront read access to all objects via OAC.
# The Condition pins the grant to this specific distribution ARN — not all CloudFront
# distributions in the account. This prevents other CF distributions from reading this bucket.
# depends_on: public access block must be applied before bucket policy can be set.
resource "aws_s3_bucket_policy" "static" {
  count  = var.enable_cloudfront ? 1 : 0
  bucket = aws_s3_bucket.static[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOAC"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.static[0].arn}/*"
        Condition = {
          StringEquals = {
            # Scoped to this specific distribution only — not all CF in the account.
            "AWS:SourceArn" = aws_cloudfront_distribution.static[0].arn
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.static]
}
