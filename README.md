# Memphis BBQ Ranking Platform

Crowdsourced restaurant ranking platform with abuse controls and reproducible infrastructure.
A full-stack, secure, cloud-native app built as a DevSecOps portfolio project.

_The BBQ is a Trojan horse. The real demo is the infrastructure, security posture, and CI/CD pipeline._

> **Status:** Currently in Phase 2 — core API endpoints. Phase 3 adds WAF, abuse controls, and security hardening.

---

## Portfolio Highlights

- Terraform IaC: multi-environment (dev/prod), remote state, zero manual console clicks
- CI/CD via GitHub Actions + OIDC — no static AWS credentials anywhere
- Auth via Cognito with least-privilege IAM per component
- WAF + rate limiting for public-facing abuse protection
- Structured JSON logs, CloudWatch alarms, cost controls
- Threat model documented; security controls traceable to specific risks

---

## Architecture Decisions

- **Compute:** AWS Lambda + API Gateway (HTTP API)
- **Language:** Python
- **Database:** DynamoDB — see data model below
- **Auth:** Cognito (user pools, JWT, `sub` as identity, email as attribute)
- **Frontend:** S3 + CloudFront
- **IaC:** Terraform
- **CI/CD:** GitHub Actions + OIDC (no long-lived keys)
- **Secrets:** SSM Parameter Store Standard (no Secrets Manager — rotation not required)
- **Environments:** dev and prod (`infra/envs/dev`, `infra/envs/prod`)
- **AWS Region:** us-east-1 exclusively
- **Single AWS account**
- **Naming convention:** `${app}-${env}-${resource}`
- **API versioning:** `/v1/`
- **All endpoints authenticated**
- **Log retention:** dev 14 days, prod 60–90 days
- **Logs:** JSON structured via CloudWatch (Lambda default); fields: level, message, requestId, userSub, route, statusCode, latencyMs, restaurantId (no PII)
- **Alarms:** Lambda errors > 0 for 5 min; 5xx rate on API Gateway
- **Ranking algorithm:** Bayesian average (fair to low-vote-count restaurants)
- **Auth flow:** API Gateway JWT authorizer → Cognito User Pool (issuer/audience); Lambda reads `sub` from `event["requestContext"]["authorizer"]["jwt"]["claims"]["sub"]`
- **Cognito UI:** Hosted UI for MVP; custom UI optional later
- **Each environment has its own Cognito User Pool** (never shared between dev/prod)

---

## Data Model

| Table | PK | SK | Purpose |
|---|---|---|---|
| `restaurants` | `restaurant_id` (slug) | — | Name, location, metadata |
| `ratings` | `user_id` (Cognito sub) | `restaurant_id` | Score 1–5, timestamps — PK/SK combo enforces one rating per user per restaurant |
| `rating_events` | `restaurant_id` | `created_at` | Append-only audit log of all rating changes |
| `leaderboard_snapshot` | `scope` (e.g. `memphis#all`) | `rank` | Denormalized read-optimized snapshot; updated inline on write now, via DynamoDB Streams later |

Notes:
- `users` table not needed — Cognito is the identity store; `sub` is the user key everywhere
- Leaderboard reads always hit `leaderboard_snapshot` (never scan `ratings` for hot reads)
- `leaderboard_snapshot` response includes a `version` field to enable polling clients and future push upgrades
- Stable `restaurant_id` slug (e.g., `paynes-bar-b-que`) used everywhere; display name is an attribute

---

## Directory Structure

```
/app
  /lambdas
    health/
    submit_rating/
    get_leaderboard/
    get_restaurants/
    get_restaurant_detail/
  /shared
    auth.py
    models.py
/infra
  /modules
    api_http/
    cognito/
    dynamodb/
    lambda/
    static_site/
  /envs
    /dev
      main.tf
      variables.tf
      terraform.tfvars
    /prod
      main.tf
      variables.tf
      terraform.tfvars
/docs
  roadmap.md
  01-product-brief.md
  02-architecture.md
  03-threat-model.md
  04-cost-estimate.md
  /adr
```
