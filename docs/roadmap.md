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

| Day | Purpose |
|---|---|
| Monday | Planning, backlog grooming, sprint goal selection |
| Wednesday | Build sprint (small, shippable slices) |
| Friday | Build sprint (small, shippable slices) |
| Saturday | Deep work (infra, security hardening, refactors) |
| Sunday (optional) | Write-up, diagrams, README updates, LinkedIn posts |

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
- [x] GitHub Actions pipeline: OIDC role assumption, `plan` on PR, `apply` on merge (user-triggered)
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

## Week 5 Sprint Plan (2026-03-30 – 2026-04-05)

**Phase:** Phase 3 — Security Hardening

**Goal:** Make DevSecOps visible and concrete. By end of Saturday: IaC scanning in CI, CloudWatch alarms live, WAF on the API, and the threat model written.

---

### Monday 2026-03-30 (Sprint 11 — IaC scanning in CI — short)

**Goal:** Pipeline blocks merges on IaC security findings. First CI security gate.

- [ ] Add `checkov` scan step to `.github/workflows/terraform.yml` — runs on every PR after `terraform plan`
- [ ] Scope to `infra/` directory; fail on HIGH/CRITICAL findings
- [ ] Fix any existing findings checkov surfaces on the current codebase
- [ ] Confirm CI gate blocks a test PR with a known-bad config, then passes on the fix

**Definition of done:** PRs touching `infra/` must pass checkov before merge. At least one finding fixed as proof it works.

---

### Wednesday 2026-04-02 (Sprint 12 — CloudWatch alarms — short)

**Goal:** Operational visibility. Know when something breaks before users report it.

- [ ] Lambda error alarm: `Errors > 0` for 5 consecutive minutes on all app Lambdas
- [ ] API Gateway alarms: 5xx rate, p99 latency > 3s, throttle count > 0
- [ ] SNS topic wired to alarms — email notification to dev address
- [ ] All alarms provisioned via Terraform in `infra/modules/` (not console clicks)
- [ ] Smoke test: invoke Lambda with bad input; confirm alarm triggers within 5 minutes

**Definition of done:** At least one alarm fires and delivers an email notification in dev.

---

### Friday 2026-04-04 (Sprint 13 — Python dependency scanning in CI — short)

**Goal:** Supply chain visibility. Know if a dependency has a known CVE before it ships.

- [ ] Add `pip-audit` scan to GitHub Actions — runs against `app/` requirements on every PR
- [ ] Pipeline fails on known vulnerabilities with no fix available
- [ ] Pin all Lambda dependencies in `app/requirements.txt` with exact versions
- [ ] Confirm CI passes on clean deps; introduce a known-bad pin to verify the gate works

**Definition of done:** PRs fail CI if `pip-audit` finds a vulnerability with a fix available.

---

### Saturday 2026-04-05 (Sprint 14 — WAF + threat model — deep work)

**Goal:** Edge protection scaffolded for prod; threat model written; Phase 3 security hardening 60%+ done.

WAF is prod-only — WebACL costs apply even with no traffic, so dev stays unprotected intentionally. The Terraform module uses a variable to gate WAF on/off per environment.

- [ ] Add `enable_waf` variable to `infra/modules/api_http/` (or a new `waf` module); default false
- [ ] Set `enable_waf = true` in `infra/envs/prod/terraform.tfvars` only
- [ ] WAF WebACL: AWS managed rules (AWSManagedRulesCommonRuleSet + AWSManagedRulesKnownBadInputsRuleSet)
- [ ] Rate limit rule: 1000 requests / 5 minutes per IP (abuse control on rating submissions)
- [ ] Associate WebACL with API Gateway stage (prod only)
- [ ] Write `docs/03-threat-model.md` — assets, threats, mitigations mapped to actual controls now in place
- [ ] Update `docs/04-cost-estimate.md` for WAF ACL + rule costs (prod only)

**Definition of done:** WAF Terraform module scaffolded; `terraform plan` for prod shows WebACL; dev plan shows no WAF resources. Threat model document committed.

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
