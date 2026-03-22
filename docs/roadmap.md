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
- [ ] Product brief (one page)
- [ ] Architecture diagram v1
- [ ] Threat model v1 (assets, threats, mitigations)
- [ ] Repo structure created (`/app`, `/infra`, `/docs`, `/docs/adr`)
- [ ] Stack decisions locked and documented in ADRs
- [ ] Initial backlog (~15–25 tickets)
- [ ] CI/CD skeleton: GitHub Actions OIDC to AWS, `terraform plan` on PR

**Definition of done:** You can explain the system clearly in 2 minutes without hand-waving. A `git push` triggers a pipeline and `terraform plan` runs with no static AWS credentials.

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

**Status:** Core auth skeleton complete. Frontend and dashboard deferred.

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
- [ ] DynamoDB tables provisioned: `restaurants`, `users`, `ratings`, `rating_events`
- [ ] Core Lambda functions deployed: `get_restaurants`, `get_restaurant_detail`, `get_leaderboard`, `submit_rating`
- [ ] REST-ish API `/v1/` endpoints live
- [ ] Unique constraint enforced: one rating per user per restaurant (update, not duplicate)
- [ ] Bayesian average ranking computed on leaderboard
- [ ] Admin path to add/edit restaurants (functional, not pretty)
- [ ] Basic input validation (score range, field length)

**Leaderboard "design now, realtime later" constraints (must hold from day one):**
- [ ] Leaderboard reads always go through `leaderboard_snapshot` — never scan `ratings` directly
- [ ] `GET /v1/leaderboard` response includes a `version` field (timestamp or counter) — enables polling clients and future push upgrades
- [ ] Leaderboard recompute is an isolated unit (inline call for now; DynamoDB Streams upgrade later with no redesign)
- [ ] Restaurant IDs are stable slugs — never key data by display name
- [ ] Scoring algorithm version is a stored attribute — makes future Bayesian → other upgrade traceable

**Definition of done:** A user can browse restaurants, submit a rating, and see the ranked leaderboard update. An admin can maintain restaurant data. All leaderboard design constraints checked off.

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

## Week 3 Sprint Plan (2026-03-16 – 2026-03-22)

_Completed sprint detail archived in [`docs/sprint-history.md`](sprint-history.md)._

- Monday: Planning complete ✓
- Sunday 2026-03-22: Sprint 6 — `GET /v1/restaurants` live ✓

---

## Week 4 Sprint Plan (2026-03-23 – 2026-03-29)

**Phase:** Phase 2 — Core Product Features (continued)

**Goal:** Close out Phase 2. By end of Saturday, all four core endpoints are live, the rating loop is functional, and the leaderboard updates on submit.

---

### Monday 2026-03-23 (Sprint 7 — `get_restaurant_detail` — short)

**Goal:** Single restaurant lookup live; 404 handling confirmed.

- [ ] Implement `app/lambdas/get_restaurant_detail/handler.py` — fetch one restaurant by `restaurant_id`; return 404 if not found
- [ ] Input validation: reject blank/missing `restaurant_id`
- [ ] Wire `GET /v1/restaurants/{id}` route in Terraform with JWT authorizer
- [ ] Lambda IAM: `dynamodb:GetItem` on `restaurants` table ARN
- [ ] Smoke test: valid ID returns restaurant, unknown ID returns clean 404

**Definition of done:** `GET /v1/restaurants/{id}` returns the correct restaurant or a clean 404.

---

### Wednesday 2026-03-25 (Sprint 8 — `get_leaderboard` — short)

**Goal:** Leaderboard read endpoint live; design constraints locked in from day one.

- [ ] Implement `app/lambdas/get_leaderboard/handler.py` — read from `leaderboard_snapshot` only (never scan `ratings`)
- [ ] Response includes `version` field (timestamp) — supports future polling/push upgrades
- [ ] Wire `GET /v1/leaderboard` route in Terraform with JWT authorizer
- [ ] Lambda IAM: `dynamodb:Query` on `leaderboard_snapshot` table ARN
- [ ] Smoke test: endpoint returns empty leaderboard (no ratings yet) with `version` field present

**Definition of done:** `GET /v1/leaderboard` returns `{"leaderboard": [], "version": "<timestamp>"}` or populated data. Never touches the `ratings` table directly.

---

### Friday 2026-03-27 (Sprint 9 — `submit_rating` write path — short)

**Goal:** Rating write path live; DynamoDB state confirmed correct before wiring leaderboard.

- [ ] Implement `app/lambdas/submit_rating/handler.py` — upsert rating in `ratings` table (PK: user sub, SK: restaurant_id); append event to `rating_events`
- [ ] Input validation: score must be integer 1–5; `restaurant_id` must be non-empty
- [ ] Wire `POST /v1/ratings` route in Terraform with JWT authorizer
- [ ] Lambda IAM: `dynamodb:PutItem` + `dynamodb:UpdateItem` on `ratings`; `dynamodb:PutItem` on `rating_events`
- [ ] Smoke test: POST a rating, verify item in DynamoDB directly; re-submit updates (does not duplicate)
- [ ] Leaderboard recompute is a stub/pass for now — wired Saturday

**Definition of done:** `POST /v1/ratings` upserts a rating and appends an audit event. Rating is idempotent. Leaderboard not yet updated.

---

### Saturday 2026-03-29 (Sprint 10 — Bayesian recompute + end-to-end — deep work)

**Goal:** Full rating loop functional. Phase 2 complete.

- [ ] Implement leaderboard recompute: Bayesian average over all ratings for each restaurant; write ranked results to `leaderboard_snapshot` with `version` (timestamp) and `algorithm_version` attribute
- [ ] Wire recompute as inline call from `submit_rating` (DynamoDB Streams upgrade path deferred to Phase 4)
- [ ] Add `dynamodb:Scan` on `ratings` + `dynamodb:PutItem` on `leaderboard_snapshot` to `submit_rating` IAM role
- [ ] Add restaurant existence check to `submit_rating`: `GetItem` on `restaurants` before accepting a rating; return 404 if not found
- [ ] End-to-end smoke test: submit a rating → `GET /v1/leaderboard` reflects updated score with new `version`
- [ ] Verify all Phase 2 leaderboard design constraints:
  - [ ] Leaderboard reads never scan `ratings`
  - [ ] Response includes `version` field
  - [ ] `algorithm_version` stored as attribute on leaderboard items
  - [ ] Restaurant IDs are stable slugs throughout

**Definition of done:** A user can submit a rating and immediately see the leaderboard update. Leaderboard response includes `version`. Rating is idempotent. All four core endpoints live in dev. Phase 2 complete.

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
