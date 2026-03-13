# Module: cognito
#
# Provisions a Cognito User Pool, App Client, and Hosted UI domain per environment.
# Each environment gets its own isolated User Pool — dev and prod never share identity.
#
# Design decisions:
#   - Email as username: standard UX for web apps; email is a verified, low-friction
#     identifier. Phone number or custom username would require extra verification flows.
#   - Hosted UI for MVP: avoids building a custom auth UI while still exercising the
#     full OAuth/OIDC flow. Custom UI can be layered on in Phase 5 without changing
#     the backend — the JWT authorizer and token format are unaffected.
#   - Public client (no secret): appropriate for browser/CLI consumers that can't
#     safely store a secret. If a server-side BFF is added later, a separate
#     confidential client can be created alongside this one.
#   - Authorization code flow only: safest OAuth 2.0 grant — the token is never
#     exposed in URL fragments (unlike implicit flow) and the code is single-use.
#   - MFA = OFF for MVP: revisited in Phase 3 security hardening. The config is
#     explicit here so it's a visible, deliberate choice rather than a default.
#
# Security implications:
#   - user_pool_add_ons.advanced_security_mode = OFF: enables anomaly detection
#     and compromised credential checks when set to AUDIT or ENFORCED. Left OFF
#     to avoid the additional per-MAU cost for MVP; upgrade in Phase 3.
#   - ALLOW_USER_PASSWORD_AUTH: convenient for CLI token issuance during testing
#     (avoids full browser OAuth round-trip). Remove for Phase 3 hardening once
#     the Hosted UI flow is the only supported entry point.
#   - Token validity: 60-min access tokens limit the blast radius of a leaked token.
#     Refresh tokens are 30 days — appropriate for a non-financial app at this stage.

locals {
  name = "${var.app_name}-${var.environment}"
}

# --- Cognito User Pool ---
resource "aws_cognito_user_pool" "this" {
  name = "${local.name}-users"

  # Email as the login identifier. Users never set a separate username.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Password policy: NIST 800-63B aligned — length over complexity.
  # Symbols add friction without meaningful security gain at this stage;
  # the 12-char minimum provides ~72 bits of entropy for random passwords.
  password_policy {
    minimum_length                   = 12
    require_uppercase                = true
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # Recovery via email only — no SMS. Avoids Cognito SMS costs and SIM-swap
  # risk (SMS OTP is weaker than email OTP against targeted attacks).
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Require email verification code before first sign-in.
  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
  }

  mfa_configuration = "OFF" # Revisit in Phase 3 — flip to OPTIONAL or REQUIRED

  # Advanced security (anomaly detection, compromised credentials): OFF for MVP.
  # Upgrade to AUDIT in Phase 3 before the first real user traffic.
  user_pool_add_ons {
    advanced_security_mode = "OFF"
  }
}

# --- Hosted UI Domain ---
# Cognito-managed subdomain — no custom domain for MVP.
# URL: https://<domain_prefix>.auth.us-east-1.amazoncognito.com
resource "aws_cognito_user_pool_domain" "this" {
  domain       = var.domain_prefix
  user_pool_id = aws_cognito_user_pool.this.id
}

# --- App Client ---
# Used by the Hosted UI and for direct token issuance in CLI testing.
resource "aws_cognito_user_pool_client" "this" {
  name         = "${local.name}-client"
  user_pool_id = aws_cognito_user_pool.this.id

  # Public client — no server-side secret storage. If a BFF is added, create
  # a separate confidential client alongside this one.
  generate_secret = false

  # OAuth: authorization code flow only (implicit and client_credentials disabled).
  # allowed_oauth_flows_user_pool_client must be true to enable OAuth on this client.
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  callback_urls = var.callback_urls
  logout_urls   = var.logout_urls

  # ALLOW_USER_SRP_AUTH: default secure flow (SRP avoids sending password to server).
  # ALLOW_USER_PASSWORD_AUTH: added for CLI testing convenience.
  # ALLOW_REFRESH_TOKEN_AUTH: required — without it no token can be refreshed.
  # Phase 3: evaluate removing ALLOW_USER_PASSWORD_AUTH once Hosted UI is primary.
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # Short-lived access and ID tokens limit blast radius of token leakage.
  access_token_validity  = 60 # minutes
  id_token_validity      = 60 # minutes
  refresh_token_validity = 30 # days

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}
