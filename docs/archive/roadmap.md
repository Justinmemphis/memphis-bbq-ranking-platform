# Project Roadmap & Timeline

Memphis BBQ Ranking Platform — DevSecOps Portfolio Project

## Strategic Framing

The goal of this project is not to build a BBQ app. The goal is to demonstrate production-grade cloud engineering discipline across:

- Infrastructure as Code (Terraform)
- CI/CD without long-lived secrets (GitHub Actions + OIDC)
- Security as a first-class concern (WAF, GuardDuty, IAM least-privilege, secrets management)
- Observability (structured logs, CloudWatch, alarms)
- Resilience and operability (health checks, rolling deploys, failure drills)
- Clear documentation (architecture, threat model, ADRs, tradeoffs)

The app is Memphis BBQ. The portfolio signal is production-grade cloud security engineering.

**Architecture sanity check:** "If the BBQ restaurants were swapped for Nashville coffee shops tomorrow, would the architecture still be impressive?" If yes, it's built correctly.

**Scope note:** The app UI uses a consumer brand ("Best Memphis BBQ" or similar). The GitHub repo name (`memphis-bbq-ranking-platform`) signals a system, not a menu. README positioning: "Crowdsourced ranking platform with abuse controls and reproducible infrastructure."

---

---

## Phase Overview

### Phase 0 — Week 1: Product + Architecture Foundation

**Objective:** Reduce ambiguity so every work session has a clear target.

**Deliverables:**
- [x] Repo structure created (`/app`, `/infra`, `/docs`, `/docs/adr`)
- [x] Stack decisions locked and documented in ADRs
- [x] CI/CD skeleton: GitHub Actions OIDC to AWS, `terraform plan` on PR
- [ ] Product brief (`docs/01-product-brief.md`) — deferred
- [ ] Architecture diagram v1 (`docs/02-architecture.md`) — deferred
- [ ] Threat model v1 (`docs/03-threat-model.md`) — deferred to Phase 3
- [ ] Initial backlog in GitHub Projects — deferred

**Definition of done:** You can explain the system clearly in 2 minutes without hand-waving. A `git push` triggers a pipeline and `terraform plan` runs with no static AWS credentials.

**Status:** Core scaffold and CI/CD complete. Docs (brief, diagram, threat model) deferred; threat model targeted for Phase 3.

---

### Phase 1 — Weeks 2–3: "Hello, Production" Skeleton

**Objective:** First end-to-end deployment, minimal features.

**Deliverables:**
- [x] Terraform foundation: remote state (S3 + DynamoDB lock), environments (dev/prod), baseline networking
- [x] GitHub Actions pipeline: OIDC role assumption, `plan` on PR, `apply` on merge (CI-only via OIDC — ADR 0002)
- [ ] Frontend skeleton deployed: S3 + CloudFront, even just "Coming Soon" — deferred to Phase 2
- [x] Backend skeleton deployed: Lambda + API Gateway `/health` endpoint
- [ ] Observability baseline: structured logs done; CloudWatch dashboard deferred to Phase 4
- [x] Auth chain verified end-to-end: `GET /v1/health` returns caller's `sub` (proves JWT authorizer → Lambda works)
- [x] Each environment has its own Cognito User Pool (dev/prod never share)

**Definition of done:** `git push` → pipeline → working public URL. No static AWS credentials anywhere. Auth chain verified via `/v1/health`.

**Status:** Complete. Auth chain verified end-to-end. Frontend (S3 + CloudFront) and CloudWatch dashboard deferred to Phase 3/4.

---

### Phase 2 — Weeks 4–5: Core Product Features (Thin but Real)

**Objective:** The app does the basic user job.

**Rating system:** Option A — users give each restaurant a score (1–5) with optional tags. One active rating per user per restaurant (updatable). Ranking computed via Bayesian average to avoid unfair weighting of low-vote-count restaurants.

**Data model (DynamoDB key schema):**

| Table | PK | SK | Notes |
|---|---|---|---|
| `restaurants` | `restaurant_id` (slug) | — | Stable slug ID; display name is an attribute |
| `ratings` | `user_id` (Cognito sub) | `restaurant_id` | PK+SK combo enforces one rating per user per restaurant |
| `rating_events` | `restaurant_id` | `created_at` | Append-only audit log |
| `leaderboard_snapshot` | `scope` (`memphis#all`) | `rank` | Denormalized read snapshot; includes `version` field |

No `users` table needed — Cognito is the identity store. `sub` is the user key everywhere.

Leaderboard reads always hit `leaderboard_snapshot` (never scan `ratings` on hot reads). Updated inline on write for MVP; DynamoDB Streams → aggregator Lambda later.

**Deliverables:**
- [x] DynamoDB tables provisioned: `restaurants`, `ratings`, `rating_events`, `leaderboard_snapshot`
- [x] Core Lambda functions deployed: `get_restaurants`, `get_restaurant_detail`, `get_leaderboard`, `submit_rating`
- [x] REST-ish API `/v1/` endpoints live
- [x] Unique constraint enforced: one rating per user per restaurant (update, not duplicate)
- [x] Bayesian average ranking computed on leaderboard
- [x] Basic input validation (score range, field length)
- [ ] Admin path to add/edit restaurants — deferred to Phase 3

**Leaderboard "design now, realtime later" constraints:**
- [x] Leaderboard reads always go through `leaderboard_snapshot` — never scan `ratings` directly
- [x] `GET /v1/leaderboard` response includes a `version` field (timestamp)
- [x] Leaderboard recompute is an isolated unit (inline call; DynamoDB Streams upgrade path preserved)
- [x] Restaurant IDs are stable slugs — never key data by display name
- [x] Scoring algorithm version is a stored attribute (`algorithm_version: "bayesian-v1"`)

**Definition of done:** A user can browse restaurants, submit a rating, and see the ranked leaderboard update. An admin can maintain restaurant data. All leaderboard design constraints checked off.

**Status:** Complete 2026-03-28. All four endpoints live in dev, end-to-end smoke tested. Admin path deferred to Phase 3.

---

### Phase 3 — Weeks 6–7: Security Hardening

**Objective:** DevSecOps becomes visible, not implied.

**Key threat surface:** user-submitted ratings introduce identity, abuse, and data integrity risk. Each control below maps to a specific threat.

**Deliverables:**

Auth + identity:
- [x] Cognito auth: user pools, roles/claims, least-privilege IAM per component
- [x] All endpoints authenticated; JWT validated server-side
- [x] `sub` used as stable user identity (not mutable email)
- [x] Cognito `admin` group: assign group to admin users; all admin routes verify group membership server-side (Sprint 23)
- [x] Admin Lambda functions: list users, create user, disable/enable user, force password reset — exposed under `/v1/admin/` routes, 403 if caller is not in `admin` group (Sprint 24)
- [x] Admin UI: pure HTML + vanilla JS (no build step), deployed to S3 + CloudFront; redirects to Cognito Hosted UI for login, checks `cognito:groups` claim, calls admin Lambda routes — also delivers the deferred Sprint 3 static site work (Sprint 25)

Abuse controls (user-submitted content):
- [x] Rate limiting on rating submissions: per-IP via WAF rate rule (Sprint 15); Lambda-level per-user throttle deferred to Phase 4
- [x] Input validation + sanitization on all user-supplied fields (score range, comment length/content)
- [ ] New account throttle: limit rating volume from recently created accounts — deferred to Phase 4
- [x] CloudWatch alarm on rating submission spikes (potential bot or stuffing attack) (Sprint 19)
- [x] `rating_events` audit log populated and queryable (Sprint 25)

Edge + infra security:
- [x] CloudFront + WAF: common threat protections (OWASP rule set), rate limits (Sprints 21–22)
- [x] Secrets in SSM Parameter Store Standard — no plaintext config anywhere (Secrets Manager not used) (Sprint 19)
- [x] No public RDS / no direct DB access from internet (N/A — DynamoDB; no VPC required)
- [x] Security groups locked to least required access (N/A — Lambda architecture; no VPC/security groups)

CI security checks:
- [x] IaC scanning in CI: checkov (Sprint 11)
- [x] Dependency scanning for Python app code: pip-audit (Sprint 13)
- [x] Pipeline blocks merge on scan failures (Sprint 11)

Observability:
- [x] Structured JSON logs (fields: level, message, requestId, userSub, route, statusCode, latencyMs, restaurantId — no PII); dev retention 14 days, prod 60–90 days (Sprint 20)
- [x] Alarms: Lambda errors > 0 for 5 min; 5xx rate, latency, throttles on API Gateway (Sprint 12)
- [x] Threat model v2: updated to reflect actual attack surface and controls in place (Sprint 25)

**Definition of done:** You can point concretely (not vibes) to how each major abuse vector is mitigated — rating stuffing, privilege escalation, injection, secrets exposure.

**Status:** Complete 2026-04-20. Two items deferred to Phase 4: Lambda-level per-user rate limiting and new account throttle.

---

### Pre-Prod Checklist (complete before any `terraform apply` against prod)

All infrastructure is scaffolded and validated in dev first. When ready to flip to prod:

- [x] **Checkov required status check:** Add `IaC Security Scan (checkov)` as a required status check in GitHub → Settings → Branches → Branch protection rules for `main`. Checkov must block merges before prod is live — without this the gate is advisory only.
- [x] **Checkov skips documented:** All 7 required skips are in `.github/workflows/terraform.yml` with written justifications (plus 4 additional: CKV_AWS_115, CKV_AWS_116, CKV_AWS_272, CKV2_AWS_29).
- [x] GitHub Actions: `terraform apply` on merge to main wired for dev and prod (Sprint 18 — `plan-prod` + `apply-prod` jobs added; `prod` GitHub environment created).
- [x] OIDC role: WAF permissions added (Sprint 18) — `wafv2:*`, `logs:PutResourcePolicy`, WAF log group pattern. **Requires manual `terraform apply` in `infra/github-oidc/` before prod CI can succeed.**
- [x] WAF WebACL: `enable_waf = true` confirmed in `infra/envs/prod/terraform.tfvars`.
- [x] Cognito prod User Pool: verify domain prefix (`bbq-ranking-prod`) is globally available — confirmed by `terraform plan` output.
- [x] Review all prod `terraform.tfvars` values — clean; no dev defaults; email via env var.
- [x] **Prod GitHub environment secrets:** `AWS_OIDC_ROLE_ARN` is a repo-level secret inherited by all environments — no per-environment override needed. Set `ALARM_NOTIFICATION_EMAIL` in GitHub → Settings → Environments → prod only.
- [ ] **Apply OIDC role expansion locally:** `cd infra/github-oidc && terraform init && terraform apply` — must run before prod CI jobs can assume WAF permissions.
- [ ] Run `terraform plan` against prod and review line-by-line before first apply.
- [ ] Tag first prod release: `v0.1.0`

**Deployment model:**
- Dev: `terraform apply` runs in GitHub Actions on merge to main (CI-only since 2026-04-04 — ADR 0002)
- Prod: `terraform apply` runs in GitHub Actions only, triggered by merge to main via OIDC — no local apply to prod ever

---

### Phase 4 — Operability + Resilience + Tests

**Objective:** Prove you can run the thing. Prod fully live, observable, and tested.

**Prod — complete these first:**
- [ ] Apply OIDC role expansion: `cd infra/github-oidc && terraform init && terraform apply` — required before prod CI can assume WAF permissions
- [ ] Run `terraform plan` against prod and review line-by-line
- [ ] Merge a prod-targeting change to main; confirm `apply-prod` CI job succeeds end-to-end
- [ ] Tag first prod release: `v0.1.0`

**Operability + Resilience:**
- [x] App-only CI deploy: `app-deploy.yml` — `terraform apply -target` for all Lambda modules + admin S3 objects; smoke test per env; prod gated on dev
- [ ] SLO targets defined: latency p99 < 500 ms, error rate < 1%, uptime > 99.5% — document targets and rationale
- [ ] Alarms confirmed end-to-end: SNS email subscription verified; test alarm fires and email is received
- [ ] CloudWatch dashboard: login frequency, rating submission volume per user, `rating_events` audit log queries — ops visibility + abuse investigation
- [ ] Basic load/stress test: k6 or Artillery; document results; confirm alarms fire under load
- [ ] Chaos drill: intentionally break a Lambda IAM permission; document detection time and remediation steps
- [ ] Cost controls: AWS Budgets alert at $10/month threshold; teardown runbook
- [ ] Runbook: incident response steps for the most likely failure modes (Lambda error spike, 5xx surge, alarm fires)

**Tests (after prod is live):**
- [ ] Unit tests: Lambda handler logic — happy path, auth rejection, invalid input, DynamoDB error cases
- [ ] Integration tests: end-to-end API calls against dev environment (real DynamoDB, real Cognito JWT)
- [ ] Infra tests: Terraform module validation with Terratest or `terraform test` — confirm resources are created with correct attributes, IAM policies are scoped correctly
- [ ] CI: unit + integration tests run on every PR; infra tests run on `infra/**` changes

**Deferred from Phase 3 (tackle after prod is live):**
- [ ] Lambda-level per-user rate limiting: enforce per-user submission rate cap in `submit_rating` handler
- [ ] New account throttle: limit rating volume from accounts created within last N days

**Definition of done:** Prod is live, observable, and tested. You can tell the story of an incident — detection, response, remediation.

---

### Phase 5 — Week 10: Portfolio Polish

**Objective:** Turn the project into a hiring asset.

**Deliverables:**
- [ ] README as mini case study: problem → architecture → security → CI/CD → ops → tradeoffs
- [ ] Clean architecture diagram (final version)
- [ ] Short demo video or GIF
- [ ] "Future work / what I'd improve" section
- [ ] Resume bullets drafted and ready

**Definition of done:** A stranger can understand and trust the project in 5 minutes.

---

## Weeks 3–4 Sprint Plans (2026-03-16 – 2026-03-28)

_Completed sprint detail archived in [`docs/sprint-history.md`](sprint-history.md)._

- Sprint 6 (2026-03-22): `GET /v1/restaurants` live ✓
- Sprint 7 (2026-03-23): `GET /v1/restaurants/{id}` live ✓
- Sprint 8 (2026-03-25): `GET /v1/leaderboard` live ✓
- Sprint 9 (2026-03-27): `POST /v1/ratings` write path live ✓
- Sprint 10 (2026-03-28): Bayesian recompute wired; Phase 2 complete ✓

---

## Week 5 (2026-03-30 – 2026-04-04)

**Phase:** Phase 3 — Security Hardening

_Completed sprint detail archived in [`docs/sprint-history.md`](sprint-history.md)._

- Sprint 11 (2026-03-30): Checkov IaC scanning in CI ✓
- Sprint 12 (2026-04-01): CloudWatch alarms live in dev ✓
- Sprint 13 (2026-04-04): Python lint + pip-audit dependency scanning in CI ✓
- Housekeeping (2026-04-04): OIDC permissions fixed; SNS subscription imported; CI-only apply for all environments (ADR 0002) ✓

---

## Week 6 (2026-04-05 – 2026-04-11)

**Phase:** Phase 3 — Security Hardening (continued)

_Completed sprint detail archived in [`docs/sprint-history.md`](sprint-history.md)._

- Sprint 14 (2026-04-05): WAF module scaffold ✓
- Sprint 15 (2026-04-06): WAF rules + rate limit; full prod infra wired ✓
- Sprint 16 (2026-04-07): Threat model written; cost estimate updated ✓
- Sprint 17 (2026-04-08): Checkov required status check; WAF association deferred to CloudFront scope; prod apply clean ✓
- Sprint 19 (2026-04-10): SSM audit; rating spike alarm deployed ✓
- Sprint 20 (2026-04-11): Structured logging audit; CI path filter fixed ✓

---

## Week 7 Sprint Plan (2026-04-14 – 2026-04-19)

**Phase:** Phase 3 — Security Hardening (continued)

**Goal:** CloudFront + WAF live, admin group + routes wired, audit log queryable, admin UI deployed. Closes out the majority of Phase 3 deliverables.

_All sprints complete. Merged via PR #38 (2026-04-20)._

- Sprint 21 (2026-04-15): CloudFront + S3 static site with OAC ✓ (PR #34)
- Sprint 22 (2026-04-19): WAF re-scoped to CLOUDFRONT; associated with CloudFront via `web_acl_id` ✓
- Sprint 23 (2026-04-19): `admin` Cognito group + `is_admin()` server-side guard; `GET /v1/admin/health` ✓
- Sprint 24 (2026-04-19): `GET /v1/admin/users` + `POST /v1/admin/users/{sub}/action` ✓
- Sprint 25 (2026-04-19): `GET /v1/admin/audit-log`; admin UI deployed to S3/CloudFront; threat model v2 ✓

---

## Portfolio Communication Strategy

Post 3–5 high-quality technical write-ups over the life of the project, not daily updates. Each post should anchor to a specific technical concept (Terraform, OIDC, WAF, IAM, CI/CD) — not the BBQ theme.

Good post topics:
- "Designing a secure AWS deployment pipeline with GitHub OIDC (no static keys)"
- "How I structured Terraform modules for multi-environment deployments"
- "Adding WAF + rate limiting to protect a public-facing serverless app"
- "Breaking my own IAM permissions to test detection and response"
- "What I'd change if I had more time: lessons from a production-style DevSecOps build"

Format: one clear technical insight + one architectural decision + one diagram or screenshot + one lesson learned.

---

## AI-Assisted Development Approach

**Approximately 70% of implementation is AI-accelerated; 30% is explicit developer verification and explanation. Nothing ships if the developer can't explain it in plain English.**

### What AI handles
- Boilerplate and scaffolding (Terraform modules, GitHub Actions workflows, folder layout)
- "Translate intent into code" — developer specifies, AI implements
- Repetitive blocks: IAM policies, variable docs, security group rules
- Tests, linters, pre-commit config, TF docs, OpenAPI docs
- Option exploration: "Give me 3 approaches; compare cost/security/complexity"

### Developer-owned decisions (non-negotiable)
- All architecture and data model decisions
- Security reasoning: why each IAM policy is least-privilege, how OIDC trust is scoped, threat model decisions
- Verification of anything touching: IAM, networking, auth, data deletion, billing
- The final "why" written in the developer's own words for README, docs, and posts

### Per-task workflow
1. Write a mini-spec (10 bullets max): inputs, outputs, constraints, definition of done
2. Implement + annotate (why it exists, security implications, alternatives)
3. Run verification checklist: `terraform fmt` + `validate` + `tflint` + plan reviewed line-by-line + IAM policy scope check + cost sanity check
4. Rewrite the final explanation in plain language

### Decision documentation (per major component)
For every significant chunk, capture in notes/README:
- What it does
- Why it's designed this way
- Main risk
- How it's mitigated
- What would improve with more time

### Framing
> "AI tooling accelerated implementation, but architecture, security decisions, and validation were developer-owned — plans, tests, policy scope, CI/CD controls."

---

## Modern Software Design Principles (Working Rules)

- **Vertical slices only:** every sprint produces something deployable or operationally demonstrable
- **Definition of done per slice:** deployed + tested + documented before moving on
- **Docs-as-code:** `/docs` folder updated every Sunday or same session as related changes
- **ADRs for key decisions:** one page each, in `/docs/adr/`
- **Interfaces first:** define API contracts and data shapes early; implementations can evolve
- **CI guardrails:** pipeline blocks merges on lint/test/security scan failures
