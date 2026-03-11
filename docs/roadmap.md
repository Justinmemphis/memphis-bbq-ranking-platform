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

**Sanity check (run this before any design decision):** "If I swapped BBQ restaurants for Nashville coffee shops tomorrow, would the architecture still be impressive?" If yes, you're building it correctly.

**Branding note:** The app UI can use a consumer brand ("Best Memphis BBQ" or similar). The GitHub repo name (`memphis-bbq-ranking-platform`) signals a system, not a menu. README positioning: "Crowdsourced ranking platform with abuse controls and reproducible infrastructure."

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
- [ ] Terraform foundation: remote state (S3 + DynamoDB lock), environments (dev/prod), baseline networking
- [ ] GitHub Actions pipeline: OIDC role assumption, `plan` on PR, `apply` on merge (user-triggered)
- [ ] Frontend skeleton deployed: S3 + CloudFront, even just "Coming Soon"
- [ ] Backend skeleton deployed: Lambda + API Gateway `/health` endpoint
- [ ] Observability baseline: structured logs, basic CloudWatch dashboard

- [ ] Auth chain verified end-to-end: `GET /v1/health` returns caller's `sub` (proves JWT authorizer → Lambda works)
- [ ] Each environment has its own Cognito User Pool (dev/prod never share)

**Definition of done:** `git push` → pipeline → working public URL. No static AWS credentials anywhere. Auth chain verified via `/v1/health`.

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

## Week 1 Sprint Plan (Detailed)

### Monday (Planning Day — complete)

- [x] Finalize and document stack decisions (ADR) — `docs/adr/0001-stack-choice.md`
- [x] Set up repo directory structure — all scaffolding created and committed
- [x] CLAUDE.md workflow rules, AI usage policy, SDLC principles
- [x] `docs/roadmap.md` — 10-week phase plan with sprint detail
- [x] `docs/04-cost-estimate.md` — per-phase AWS cost breakdown
- [x] `app/lambdas/` stubs + `app/shared/auth.py` + `app/shared/models.py`
- [x] `infra/modules/` stubs for all 5 modules
- [x] `.github/workflows/terraform.yml` — PR plan workflow skeleton
- [ ] Write product brief (`docs/01-product-brief.md`) — deferred
- [ ] Sketch architecture diagram v1 (`docs/02-architecture.md`) — deferred
- [ ] Write threat model v1 (`docs/03-threat-model.md`) — deferred
- [ ] Create initial backlog in GitHub Projects (~15 tickets) — deferred

### Wednesday (Sprint 1 — Terraform Foundation)

- [x] Create Terraform project structure under `/infra`
- [x] Configure remote state: S3 bucket (`bbq-tfstate-justin`) + DynamoDB lock table (`bbq-tfstate-lock`) created manually in AWS
- [x] Backend configured in `infra/envs/dev/backend.tf` and `infra/envs/prod/backend.tf`
- [x] `terraform init` successful — backend connected, provider lock file committed
- [x] `terraform validate` passing — configuration is valid
- [x] Deploy first real resources: all 4 DynamoDB tables deployed to dev via `terraform apply`
- [x] Confirm no manual console clicks required for subsequent deploys

**Definition of done:** Infra deploys cleanly from code. ✓ COMPLETE

### Friday (Sprint 2 — CI/CD + OIDC)

- [x] GitHub OIDC provider imported into Terraform state (pre-existed from another project)
- [x] IAM role `bbq-github-actions` created — trust scoped to this repo only
- [x] IAM policy: least privilege covering Terraform state (S3 + DynamoDB lock) and DynamoDB app tables
- [x] `infra/github-oidc/` Terraform root committed with separate state key
- [x] `AWS_OIDC_ROLE_ARN` secret added to GitHub Actions
- [x] Pipeline triggered on PR — OIDC auth succeeded, `terraform plan` passed, no static credentials

**Definition of done:** GitHub Actions assumes AWS role via OIDC and runs `terraform plan` successfully. ✓ COMPLETE

### Saturday (Deep Work — First Deployable Slice)

_Skipped — moved into Week 2 sprints._

---

## Week 2 Sprint Plan

**Goal:** By end of Friday, have a live public URL (CloudFront), a working authenticated API endpoint, and a Cognito User Pool — the full "Hello, Production" skeleton from Phase 1.

No Saturday this week.

---

### Monday (Sprint 3 — Static Site: S3 + CloudFront)

**Goal:** First public URL deployed from code.

- [ ] Implement `infra/modules/static_site/`: private S3 bucket + CloudFront distribution with Origin Access Control (OAC)
- [ ] Wire module into `infra/envs/dev/main.tf`
- [ ] Deploy minimal `index.html` ("Coming Soon") to S3
- [ ] `terraform apply` — confirm CloudFront URL is live
- [ ] Update GitHub Actions IAM policy to cover S3 + CloudFront resources

**Definition of done:** A public CloudFront URL serves content deployed entirely from Terraform + code. No manual console steps.

---

### Wednesday (Sprint 4 — Lambda + API Gateway)

**Goal:** First API endpoint live behind API Gateway.

- [x] Implement `infra/modules/lambda/`: Lambda function + IAM execution role + CloudWatch log group
- [x] Implement `infra/modules/api_http/`: API Gateway HTTP API + route + Lambda integration
- [x] Deploy `GET /v1/health` (unauthenticated for now — auth added Friday)
- [ ] Verify endpoint responds via `curl` or browser — pending `terraform apply`
- [x] Update GitHub Actions IAM policy to cover Lambda + API Gateway resources

**Definition of done:** `curl https://<api-id>.execute-api.us-east-1.amazonaws.com/v1/health` returns `{"status": "ok"}`.

---

### Friday (Sprint 5 — Cognito + Auth Wiring)

**Goal:** All endpoints authenticated; full auth chain verified end-to-end.

- [ ] Implement `infra/modules/cognito/`: User Pool + App Client (Hosted UI)
- [ ] Wire JWT authorizer onto API Gateway
- [ ] Update `health` Lambda to return caller's `sub` from JWT claims
- [ ] Create a test user in Cognito dev pool; obtain a token; verify `GET /v1/health` returns `sub`
- [ ] Update GitHub Actions IAM policy to cover Cognito resources

**Definition of done:** `GET /v1/health` with a valid Cognito JWT returns `{"status": "ok", "sub": "<user-sub>"}`. Unauthenticated requests return 401.

---

## LinkedIn Posting Strategy

Post 3–5 high-quality posts over the life of the project, not daily updates. Each post should anchor to a specific technical concept (Terraform, OIDC, WAF, IAM, CI/CD) — not the BBQ theme.

Good post topics:
- "Designing a secure AWS deployment pipeline with GitHub OIDC (no static keys)"
- "How I structured Terraform modules for multi-environment deployments"
- "Adding WAF + rate limiting to protect a public-facing serverless app"
- "Breaking my own IAM permissions to test detection and response"
- "What I'd change if I had more time: lessons from a production-style DevSecOps build"

Format: one clear technical insight + one architectural decision + one diagram or screenshot + one lesson learned.

---

## AI Usage Policy (Claude Code)

**70% AI writes and refactors. 30% you verify and explain. If you can't explain a block in plain English, it doesn't ship.**

### What AI handles
- Boilerplate and scaffolding (Terraform modules, GitHub Actions workflows, folder layout)
- "Translate my intent into code" — you specify, AI implements
- Repetitive blocks: IAM policies, variable docs, security group rules
- Tests, linters, pre-commit config, TF docs, OpenAPI docs
- Option exploration: "Give me 3 approaches; compare cost/security/complexity"

### What you own (non-negotiable)
- All architecture and data model decisions
- Security reasoning: why each IAM policy is least-privilege, how OIDC trust is scoped, threat model decisions
- Verification of anything touching: IAM, networking, auth, data deletion, billing
- The final "why" written in your own words for README, docs, LinkedIn

### Per-task workflow
1. You write a mini-spec (10 bullets max): inputs, outputs, constraints, definition of done
2. Ask Claude to implement + annotate (why it exists, security implications, alternatives)
3. Run verification checklist: `terraform fmt` + `validate` + `tflint` + plan reviewed line-by-line + IAM policy scope check + cost sanity check
4. You rewrite the final explanation in your own words

### Defense cards (interview-proofing)
For every major chunk, capture in notes/README:
- What it does
- Why it's designed this way
- Main risk
- How you mitigated it
- What you'd improve with more time

### How to frame it
> "I used AI tooling to accelerate implementation, but I owned architecture, security decisions, and validation — plans, tests, policy scope, CI/CD controls."

---

## Modern Software Design Principles (Working Rules)

- **Vertical slices only:** every sprint produces something deployable or operationally demonstrable
- **Definition of done per slice:** deployed + tested + documented before moving on
- **Docs-as-code:** `/docs` folder updated every Sunday or same session as related changes
- **ADRs for key decisions:** one page each, in `/docs/adr/`
- **Interfaces first:** define API contracts and data shapes early; implementations can evolve
- **CI guardrails:** pipeline blocks merges on lint/test/security scan failures
