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

## Work Cadence

Default cadence (all weeks from Week 6 onward):

| Day | Purpose |
|---|---|
| Monday–Friday | Short sprints (shippable slices) |
| Saturday | Deep work (infra, security hardening, refactors, write-ups) |
| Sunday | Deep work (continued; diagrams, ADRs, LinkedIn posts) |

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
- [ ] Cognito auth: user pools, roles/claims, least-privilege IAM per component
- [ ] All endpoints authenticated; JWT validated server-side
- [ ] `sub` used as stable user identity (not mutable email)
- [ ] Cognito `admin` group: assign group to admin users; all admin routes verify group membership server-side
- [ ] Admin Lambda functions: list users, create user, disable/enable user, force password reset — exposed under `/v1/admin/` routes, 403 if caller is not in `admin` group
- [ ] Admin UI: pure HTML + vanilla JS (no build step), deployed to S3 + CloudFront; redirects to Cognito Hosted UI for login, checks `cognito:groups` claim, calls admin Lambda routes — also delivers the deferred Sprint 3 static site work

Abuse controls (user-submitted content):
- [ ] Rate limiting on rating submissions: per-user and per-IP (WAF + Lambda-level)
- [ ] Input validation + sanitization on all user-supplied fields (score range, comment length/content)
- [ ] New account throttle: limit rating volume from recently created accounts
- [ ] CloudWatch alarm on rating submission spikes (potential bot or stuffing attack)
- [ ] `rating_events` audit log populated and queryable

Edge + infra security:
- [ ] CloudFront + WAF: common threat protections (OWASP rule set), rate limits
- [ ] Secrets in SSM Parameter Store Standard — no plaintext config anywhere (Secrets Manager not used)
- [ ] No public RDS / no direct DB access from internet
- [ ] Security groups locked to least required access

CI security checks:
- [ ] IaC scanning in CI: tfsec, trivy, or checkov (pick one, stick with it)
- [ ] Dependency scanning for Python app code
- [ ] Pipeline blocks merge on scan failures

Observability:
- [ ] Structured JSON logs (fields: level, message, requestId, userSub, route, statusCode, latencyMs, restaurantId — no PII); dev retention 14 days, prod 60–90 days
- [ ] Alarms: Lambda errors > 0 for 5 min; 5xx rate, latency, throttles on API Gateway
- [ ] Threat model v2: updated to reflect actual attack surface and controls in place

**Definition of done:** You can point concretely (not vibes) to how each major abuse vector is mitigated — rating stuffing, privilege escalation, injection, secrets exposure.

---

### Pre-Prod Checklist (complete before any `terraform apply` against prod)

All infrastructure is scaffolded and validated in dev first. When ready to flip to prod:

- [ ] **Checkov required status check:** Add `IaC Security Scan (checkov)` as a required status check in GitHub → Settings → Branches → Branch protection rules for `main`. Checkov must block merges before prod is live — without this the gate is advisory only.
- [ ] **Checkov skips documented:** Add remaining skip rules to `.github/workflows/terraform.yml` `skip_check` with written justifications: `CKV_AWS_26` (SNS KMS — Phase 3), `CKV_AWS_50` (X-Ray — Phase 4), `CKV_AWS_117` (Lambda VPC — intentional no-VPC architecture), `CKV_AWS_119` (DynamoDB KMS CMK — Phase 3), `CKV_AWS_158` (CloudWatch KMS — Phase 3), `CKV_AWS_173` (Lambda env KMS — env vars are table names only), `CKV_AWS_338` (log retention < 1 year — dev 14d/prod 60-90d by design)
- [x] GitHub Actions: `terraform apply` on merge to main wired for dev (ADR 0002) — prod apply job still needs to be scoped to `infra/envs/prod/`
- [ ] OIDC role: audit and expand permissions for prod apply (dev apply permissions already in place)
- [ ] WAF WebACL: `enable_waf = true` in `infra/envs/prod/terraform.tfvars`
- [ ] Cognito prod User Pool: verify domain prefix, client settings, and callback URLs
- [ ] Review all prod `terraform.tfvars` values — no dev defaults slipping through
- [ ] Run `terraform plan` against prod and review line-by-line before first apply
- [ ] Tag first prod release: `v0.1.0`

**Deployment model:**
- Dev: `terraform apply` runs in GitHub Actions on merge to main (CI-only since 2026-04-04 — ADR 0002)
- Prod: `terraform apply` runs in GitHub Actions only, triggered by merge to main via OIDC — no local apply to prod ever

---

### Phase 4 — Weeks 8–9: Operability + Resilience + Break & Fix

**Objective:** Prove you can run the thing.

**Deliverables:**
- [ ] SLO-style targets defined: latency, error rate, uptime
- [ ] Alarms wired to SNS/email
- [ ] Basic load/stress test (even small scale)
- [ ] Chaos drill: intentionally misconfigure a permission or endpoint, document impact, detection, and remediation
- [ ] Cost controls: AWS budgets, alerts, teardown runbook
- [ ] Runbook doc: how to respond to a basic incident
- [ ] User activity monitoring: CloudWatch dashboard surfacing login frequency, rating submission volume per user, and `rating_events` audit log queries — supports both ops visibility and abuse investigation

**Definition of done:** You can tell the story of an incident and how you detected, responded, and fixed it.

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

## Week 6 Sprint Plan (2026-04-05 – 2026-04-10)

**Phase:** Phase 3 — Security Hardening (continued)

**Goal:** WAF scaffolded for prod, threat model written, branch protection hardened, secrets moved to SSM. Six short sprints Sun–Fri; no Saturday session this week. Week 7 opens with a long session Sunday 2026-04-12.

---

### Sunday 2026-04-05 (Sprint 14 — WAF module scaffold — short)

**Goal:** Create the WAF Terraform module skeleton and wire the `enable_waf` flag into both environments.

- [ ] Create `infra/modules/waf/` module: `main.tf`, `variables.tf`, `outputs.tf`
- [ ] `enable_waf` variable (default false); module creates no resources when false
- [ ] WAF WebACL resource with `scope = "REGIONAL"` (API Gateway)
- [ ] Set `enable_waf = false` in dev tfvars; `enable_waf = true` in prod tfvars
- [ ] `terraform plan` for dev shows no WAF resources; prod plan shows WebACL stub

**Definition of done:** WAF module exists; dev plan clean; prod plan shows WebACL resource.

---

### Monday 2026-04-06 (Sprint 15 — WAF rules + rate limit — short)

**Goal:** Add AWS managed rule groups and a per-IP rate limit rule to the WAF module.

- [ ] AWS managed rules: `AWSManagedRulesCommonRuleSet` + `AWSManagedRulesKnownBadInputsRuleSet`
- [ ] Rate limit rule: 1000 requests / 5 minutes per IP (abuse control on rating submissions)
- [ ] Associate WebACL with API Gateway stage when `enable_waf = true`
- [ ] `terraform plan` for prod shows all rules and association; dev plan still clean

**Definition of done:** Prod plan shows full WAF WebACL with managed rules and rate limit; dev unaffected.

---

### Tuesday 2026-04-07 (Sprint 16 — Threat model — short)

**Goal:** Document the actual attack surface and controls in place. Writing sprint.

- [ ] Write `docs/03-threat-model.md` — assets, threats (rating stuffing, privilege escalation, injection, secrets exposure), mitigations mapped to actual controls
- [ ] Update `docs/04-cost-estimate.md` to include WAF ACL + rule costs (prod only)

**Definition of done:** Threat model committed; every major threat has a named control mapped to it; cost estimate updated.

---

### Wednesday 2026-04-08 (Sprint 17 — Branch protection + checkov required — short)

**Goal:** Make checkov a hard CI gate, not advisory.

- [ ] Add `IaC Security Scan (checkov)` as required status check in GitHub → Settings → Branches → branch protection for `main`
- [ ] Verify all 7 documented Checkov skip rules are in `.github/workflows/terraform.yml` with written justifications
- [ ] Open and merge a test PR to confirm checkov blocks/passes correctly

**Definition of done:** Checkov is a required status check; a failed checkov blocks merge.

---

### Thursday 2026-04-09 (Sprint 18 — Pre-prod checklist review — short)

**Goal:** Audit the pre-prod checklist and prod tfvars before any prod apply.

- [ ] Review full pre-prod checklist line-by-line; mark completed items, identify gaps
- [ ] Verify `infra/envs/prod/terraform.tfvars` — confirm no dev defaults slipping through
- [ ] Run `terraform plan` against prod and review output line-by-line
- [ ] Document any remaining blockers before prod is live

**Definition of done:** Pre-prod checklist updated; prod plan reviewed and no surprises.

---

### Friday 2026-04-10 (Sprint 19 — Secrets in SSM Parameter Store — short)

**Goal:** Move any plaintext config out of Lambda env vars and into SSM. No secrets in code or tfvars.

- [ ] Identify all plaintext config currently passed as Lambda env vars (table names are fine; anything credential-like is not)
- [ ] Add SSM Parameter Store resources in Terraform for any true secrets
- [ ] Update Lambda IAM roles with least-privilege `ssm:GetParameter` permissions
- [ ] Verify Lambda can read secrets at runtime; no plaintext secrets remain in Terraform or env vars

**Definition of done:** All secrets are in SSM; Lambda IAM grants only the params it needs; no plaintext secrets in code.

---

### Sunday 2026-04-12 (Deep work — Week 7 kickoff)

**Goal:** Long session to open Week 7. Candidate topics: Admin Cognito group + admin route guard, Admin UI scaffold (S3 + CloudFront), or structured logging audit — pick one based on energy and priority.

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
