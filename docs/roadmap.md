# Project Roadmap

Memphis BBQ Ranking Platform — DevSecOps Portfolio Project

**Last updated:** 2026-05-07

---

## Strategic Framing

The goal is not to build a BBQ app. The goal is to demonstrate production-grade cloud
engineering discipline: IaC, CI/CD without long-lived secrets, security as a first-class
concern, observability, resilience, and clear documentation.

The app is Memphis BBQ. The portfolio signal is production-grade cloud security engineering.

> "If the BBQ restaurants were swapped for Nashville coffee shops tomorrow, would the
> architecture still be impressive?" If yes, it's built correctly.

---

## Current Status — 2026-05-22

**Phase 4 complete. Phase 5 (Portfolio Polish) is next.**

Prod is fully live with a real public UI. CI keeps prod in sync on every merge to main. No manual apply ever needed.

### What's done

| Area | Deliverable |
|---|---|
| **Infra** | Terraform remote state, dev + prod environments, Lambda + API Gateway, DynamoDB (4 tables), Cognito user pools, S3 + CloudFront, WAF (CLOUDFRONT scope, OWASP rules + rate limit) |
| **CI/CD** | GitHub Actions + OIDC (no static keys), `plan` on PR, `apply` on merge; app-only deploy workflow; checkov + pip-audit gating merges |
| **API** | `GET /v1/health`, `GET /v1/restaurants`, `GET /v1/restaurants/{id}`, `GET /v1/leaderboard`, `POST /v1/ratings`; Bayesian average ranking; one rating per user per restaurant |
| **Auth** | Cognito JWT on write/admin routes; read routes public; `sub` as stable identity; admin group with server-side guard |
| **Public UI** | Leaderboard + restaurant list; star rating with Cognito login redirect; dark BBQ-themed design; S3 + CloudFront |
| **Admin UI** | Pure HTML/JS deployed to S3/CloudFront; Cognito Hosted UI login; user list, disable/enable, force password reset |
| **Security** | SSM Parameter Store for secrets; structured JSON logs (no PII); `rating_events` audit log; threat model v2 |
| **Observability** | 6 CloudWatch alarms (Lambda errors, 5xx count, error rate, p99 latency, throttles, rating spike); ops dashboard (`bbq-prod-ops`); load test passed both SLOs (p99=371ms, error rate=0.00%) |
| **Operability** | IAM chaos drill + runbook; incident response runbook (5 scenarios); teardown runbook (dev + full shutdown) |

---

## Remaining Work — Prioritized

Items are ordered by value delivered vs. effort. Do them in this sequence.

---

### 1. Unit Tests + CI wiring — COMPLETE

44 tests (pytest + moto) for all 9 Lambda handlers + shared auth. Wired into CI on
every PR via `python.yml`. Merged 2026-05-07 (PR #53).

---

### 2. SNS Alarm End-to-End Verification — COMPLETE

Subscription confirmed and alarm email delivery verified manually (2026-05-07).
`bbq-prod-alarms` SNS topic subscription is active.

---

### 3. Public Landing Page — COMPLETE

Merged 2026-05-22 (PR #56). Replaced "Coming Soon" stub with a full public landing
page. `GET /v1/restaurants` and `GET /v1/leaderboard` opened to unauthenticated callers
via per-route `public = true` flag in the `api_http` Terraform module. Rating
submission redirects to Cognito Hosted UI (implicit grant, same pattern as admin UI).
`POST /v1/ratings` and all `/v1/admin/*` routes remain JWT-gated.

---

### 4. Restaurant Admin CRUD

**What:** Add create/edit/delete restaurant endpoints (`POST /v1/admin/restaurants`,
`PUT /v1/admin/restaurants/{id}`, `DELETE /v1/admin/restaurants/{id}`) and wire them
into the admin UI. Currently restaurants can only be added via direct DynamoDB writes.

**Why:** Closes the last gap in the admin capability. Required for the project to be
self-maintaining — you can't demo adding a new restaurant without console access today.
Also adds three more Lambda functions with test coverage opportunities.

**Scope:** New Lambda handlers + new API routes + admin UI additions + IAM update +
unit tests for new handlers.

---

### 5. Lambda-Level Per-User Rate Limiting

**What:** Enforce a per-user submission cap in the `submit_rating` handler — e.g. max
10 ratings per user per hour. Track submission timestamps in DynamoDB (or a TTL-based
counter) and reject with 429 if the cap is exceeded.

**Why:** WAF handles per-IP limits; this handles the case where one user (one Cognito
`sub`) submits ratings from many IPs or rotates through proxies. Deferred twice from
Phase 3. Completes the abuse control story.

**Scope:** `submit_rating` handler change + new DynamoDB access pattern + unit tests.
No Terraform changes unless a new table or index is needed.

---

### 6. New Account Throttle

**What:** Limit rating volume from accounts created within the last N days (e.g. 3
ratings/day for accounts < 7 days old). Deters throwaway-account abuse.

**Why:** Complements per-user rate limiting. The threat model identifies new-account
stuffing as a vector; this closes it.

**Scope:** `submit_rating` handler change + Cognito `UserCreateDate` claim check.
No new infrastructure needed.

---

### 7. Integration Tests

**What:** End-to-end API calls against the real dev environment — real DynamoDB, real
Cognito JWT. Tests verify actual HTTP responses, not mocked ones.

**Why:** Catches divergence between mocked unit tests and actual AWS behavior (auth
header format, DynamoDB response shape, API Gateway passthrough quirks).

**Scope:** pytest + `requests`, test Cognito user in dev, wired into CI on a separate
job that runs on `main` only (not every PR, to avoid live AWS cost on every branch).

**Dependency:** Requires a long-lived test user in dev Cognito pool with a stable
password stored in GitHub Secrets.

---

### 8. Infra Tests

**What:** Validate Terraform modules produce correctly configured resources.
`terraform test` (native HCL, no Go required) is the right tool here — tests that
specific outputs exist, IAM policies are scoped correctly, and no `Resource: "*"`
appears where it shouldn't.

**Why:** Catches IaC regressions — a module change that silently widens an IAM policy
or removes an encryption setting wouldn't be caught by unit or integration tests.

**Scope:** `*.tftest.hcl` files per module, wired into CI on `infra/**` changes.

---

### 9. Architecture Diagram

**What:** A clean diagram of the full prod architecture: CloudFront → WAF → API
Gateway → Lambda → DynamoDB, plus Cognito, S3, CloudWatch, GitHub Actions OIDC.
Mermaid or draw.io; lives in `docs/02-architecture.md`.

**Why:** Required for Phase 5 portfolio polish. A recruiter should be able to
understand the system in 30 seconds from the diagram. Also useful to have before
writing the README case study.

**Scope:** Docs only.

---

### 10. Phase 5 — Portfolio Polish

**What:**
- README as mini case study: problem → architecture → security → CI/CD → ops → tradeoffs
- Architecture diagram (item 9 above, referenced from README)
- "What I'd improve with more time" section
- Resume bullets drafted
- Optional: short demo video or GIF of the public UI (item 3) + admin UI

**Why:** Turns the project into a hiring asset. Everything before this is engineering;
this is communication.

**Scope:** Pure writing + one diagram. No code changes.

---

## Skipped / Out of Scope

| Item | Decision |
|---|---|
| Product brief (`docs/01-product-brief.md`) | Skipped — subsumed by README case study in Phase 5 |
| GitHub Projects backlog | Skipped — roadmap.md is sufficient for a solo project |
| AWS Budgets alert | Skipped — shared personal account; fixed threshold meaningless without cost allocation tags |
| GuardDuty | Not yet decided — $1–3/month, prod only; add if Phase 5 polish warrants it |
| Route 53 custom domain | Not yet decided — $0.50/month; adds realism to portfolio but not required |
| DynamoDB Streams → aggregator Lambda | Deferred indefinitely — leaderboard recompute is inline for MVP; upgrade path is preserved |
| Secrets Manager (vs SSM) | Decided against — SSM Standard is free; Secrets Manager justified only when rotation is needed |

---

## Quick Reference — Runbooks

| Scenario | Document |
|---|---|
| Lambda IAM permission break | `docs/runbooks/iam-permission-break.md` |
| Incident response (5xx, latency, abuse, throttles) | `docs/runbooks/incident-response.md` |
| Load test results (2026-05-01 baseline) | `docs/runbooks/load-test-results.md` |
| Teardown (dev-only or full shutdown) | `docs/runbooks/teardown.md` |
