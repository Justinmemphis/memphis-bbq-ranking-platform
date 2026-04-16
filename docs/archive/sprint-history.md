# Sprint History

Memphis BBQ Ranking Platform — Completed Sprint Log

---

## Week 1 (2026-03-02 – 2026-03-07)

**Phase:** Phase 0 — Product + Architecture Foundation & Phase 1 kickoff

---

### Monday 2026-03-02 (Planning Day)

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

---

### Wednesday 2026-03-07 (Sprint 1 — Terraform Foundation)

**Goal:** Remote state configured; first real resources deployed from code.

- [x] Create Terraform project structure under `/infra`
- [x] Configure remote state: S3 bucket (`bbq-tfstate-justin`) + DynamoDB lock table (`bbq-tfstate-lock`) created manually in AWS
- [x] Backend configured in `infra/envs/dev/backend.tf` and `infra/envs/prod/backend.tf`
- [x] `terraform init` successful — backend connected, provider lock file committed
- [x] `terraform validate` passing — configuration is valid
- [x] Deploy first real resources: all 4 DynamoDB tables deployed to dev via `terraform apply`
- [x] Confirm no manual console clicks required for subsequent deploys

**Definition of done:** Infra deploys cleanly from code. ✓ COMPLETE

---

### Friday 2026-03-07 (Sprint 2 — CI/CD + OIDC)

**Goal:** GitHub Actions assumes AWS role via OIDC — no static credentials anywhere.

- [x] GitHub OIDC provider imported into Terraform state (pre-existed from another project)
- [x] IAM role `bbq-github-actions` created — trust scoped to this repo only
- [x] IAM policy: least privilege covering Terraform state (S3 + DynamoDB lock) and DynamoDB app tables
- [x] `infra/github-oidc/` Terraform root committed with separate state key
- [x] `AWS_OIDC_ROLE_ARN` secret added to GitHub Actions
- [x] Pipeline triggered on PR — OIDC auth succeeded, `terraform plan` passed, no static credentials

**Definition of done:** GitHub Actions assumes AWS role via OIDC and runs `terraform plan` successfully. ✓ COMPLETE

---

## Week 2 (2026-03-11 – 2026-03-13)

**Phase:** Phase 1 — "Hello, Production" Skeleton

No Saturday sprint this week.

---

### Monday 2026-03-07 (Sprint 3 — Static Site: S3 + CloudFront)

_Skipped — deferred to Phase 2/3 to prioritize auth chain delivery._

---

### Wednesday 2026-03-11 (Sprint 4 — Lambda + API Gateway)

**Goal:** First API endpoint live behind API Gateway.

- [x] Implement `infra/modules/lambda/`: Lambda function + IAM execution role + CloudWatch log group
- [x] Implement `infra/modules/api_http/`: API Gateway HTTP API + route + Lambda integration
- [x] Deploy `GET /v1/health` (unauthenticated for now — auth added Friday)
- [x] Verify endpoint responds via `curl` or browser
- [x] Update GitHub Actions IAM policy to cover Lambda + API Gateway resources

**Definition of done:** `curl https://<api-id>.execute-api.us-east-1.amazonaws.com/v1/health` returns `{"status": "ok"}`. ✓ COMPLETE

---

### Friday 2026-03-13 (Sprint 5 — Cognito + Auth Wiring)

**Goal:** All endpoints authenticated; full auth chain verified end-to-end.

- [x] Implement `infra/modules/cognito/`: User Pool + App Client (Hosted UI)
- [x] Wire JWT authorizer onto API Gateway
- [x] Update `health` Lambda to return caller's `sub` from JWT claims
- [x] Create a test user in Cognito dev pool; obtain a token; verify `GET /v1/health` returns `sub`
- [x] Update GitHub Actions IAM policy to cover Cognito resources

**Definition of done:** `GET /v1/health` with a valid Cognito JWT returns `{"status": "ok", "sub": "<user-sub>"}`. Unauthenticated requests return 401. ✓ COMPLETE

---

## Week 3 (2026-03-16 – 2026-03-22)

**Phase:** Phase 2 — Core Product Features

---

### Monday 2026-03-16 (Planning)

- [x] Review Phase 2 deliverables; locked week's scope
- [x] Created feature branch `feature/week3-core-endpoints`
- [x] Confirmed all 4 DynamoDB tables present in dev; restaurants table empty
- [x] Decided seed data strategy — `scripts/seed_restaurants.py`; idempotent boto3 puts
- [x] Added `additional_policy_json` variable to Lambda module for per-function IAM
- [x] Switched all Lambdas to `source_path = app/` (full app tree zip, shared/ available everywhere)
- [x] Fixed CI: `cognito-idp:DescribeUserPool` + `DescribeUserPoolDomain` added to OIDC role policy
- [x] Smoke tested `GET /v1/health` on new handler path — confirmed working
- [x] Seeded 5 Shelby County restaurants into `bbq-dev-restaurants`

---

### Sunday 2026-03-22 (Sprint 6 — `get_restaurants`)

_Wednesday and Friday sprints were not completed this week; Sprint 6 delivered on Sunday._

- [x] Implemented `app/lambdas/get_restaurants/handler.py` — DynamoDB Scan with pagination, structured JSON logging
- [x] Wired `GET /v1/restaurants` route in `infra/envs/dev/main.tf` with JWT authorizer
- [x] Lambda IAM: `dynamodb:Scan` on `bbq-dev-restaurants` ARN only
- [x] Injected `RESTAURANTS_TABLE` env var — same code works in dev and prod
- [x] Smoke tested: valid JWT returns JSON array of seeded restaurants

**Definition of done:** `GET /v1/restaurants` with a valid JWT returns a non-empty JSON array from real DynamoDB data. ✓ COMPLETE

---

## Week 4 (2026-03-23 – 2026-03-28)

**Phase:** Phase 2 — Core Product Features (continued)

---

### Monday 2026-03-23 (Sprint 7 — `get_restaurant_detail`)

- [x] Implemented `app/lambdas/get_restaurant_detail/handler.py` — GetItem by slug ID; clean 404 on unknown restaurant
- [x] Input validation: reject blank/missing `restaurant_id`
- [x] Wired `GET /v1/restaurants/{restaurant_id}` route in Terraform with JWT authorizer
- [x] Lambda IAM: `dynamodb:GetItem` on `restaurants` table ARN only
- [x] Fixed `api_http` module: `statement_id` sanitisation now strips `{}` from path parameter route keys
- [x] Smoke tested: valid ID returns restaurant; unknown ID returns clean 404

**Definition of done:** `GET /v1/restaurants/{id}` returns the correct restaurant or a clean 404. ✓ COMPLETE

---

### Wednesday 2026-03-25 (Sprint 8 — `get_leaderboard`)

- [x] Implemented `app/lambdas/get_leaderboard/handler.py` — reads `leaderboard_snapshot` only; never touches `ratings`
- [x] Response includes `version` field (ISO 8601 timestamp of last recompute)
- [x] Wired `GET /v1/leaderboard` route in Terraform with JWT authorizer
- [x] Lambda IAM: `dynamodb:Query` on `leaderboard_snapshot` ARN only
- [x] Smoke tested: empty leaderboard returns `{"leaderboard": [], "version": "<timestamp>"}`

**Definition of done:** `GET /v1/leaderboard` returns leaderboard data with `version` field. Never touches `ratings`. ✓ COMPLETE

---

### Friday 2026-03-27 (Sprint 9 — `submit_rating` write path)

- [x] Implemented `app/lambdas/submit_rating/handler.py` — upserts rating (PK: user sub, SK: restaurant_id); appends audit event to `rating_events`
- [x] Input validation: score must be integer 1–5; `restaurant_id` must be non-empty
- [x] Wired `POST /v1/ratings` route in Terraform with JWT authorizer
- [x] Lambda IAM: `dynamodb:PutItem` on `ratings` and `rating_events`
- [x] Leaderboard recompute stubbed (wired Saturday)

**Definition of done:** `POST /v1/ratings` upserts a rating and appends an audit event. ✓ COMPLETE

---

### Saturday 2026-03-28 (Sprint 10 — Bayesian recompute + end-to-end)

- [x] Implemented inline Bayesian leaderboard recompute in `submit_rating` — Bayesian C=5, m=3.0 prior; scans all ratings, ranks by score, writes to `leaderboard_snapshot` with `version` and `algorithm_version`
- [x] Added restaurant existence check to `submit_rating` — GetItem on `restaurants`; returns 404 if not found
- [x] Expanded `submit_rating` IAM: `GetItem` on restaurants, `Scan` on ratings, `Query`/`DeleteItem`/`PutItem`/`BatchWriteItem` on leaderboard_snapshot
- [x] End-to-end smoke test: submit rating → leaderboard updates with Bayesian score and new `version`
- [x] Idempotency confirmed: re-submit updates score (one DynamoDB item, no duplicate)
- [x] All Phase 2 leaderboard design constraints verified

**Definition of done:** Full rating loop functional. All four Phase 2 endpoints live in dev. Phase 2 complete. ✓ COMPLETE

---

## Week 5 (2026-03-30 – 2026-04-04)

**Phase:** Phase 3 — Security Hardening

---

### Monday 2026-03-30 (Sprint 11 — IaC scanning in CI)

- [x] Added `checkov` scan step to `.github/workflows/terraform.yml` — runs after `terraform plan` on every PR
- [x] Scoped to `infra/` directory; fails on HIGH/CRITICAL findings; MEDIUM/LOW are warnings only
- [x] Fixed DynamoDB PITR: enabled `point_in_time_recovery` on all 4 tables (CKV_AWS_28)
- [x] Documented 7 intentional checkov skips with written justifications in the workflow file
- [x] Added `security-events: write` permission to workflow for SARIF upload to GitHub Security tab
- [x] 171 checks passing, 0 failures on first clean run
- [x] Gate verified: test PR with known-bad config blocked; fix unblocked it

**Definition of done:** PRs touching `infra/` must pass checkov before merge. ✓ COMPLETE

Note: checkov is currently advisory only — must add as required status check in branch protection before prod.

---

### Wednesday 2026-04-01 (Sprint 12 — CloudWatch alarms)

- [x] Implemented `infra/modules/alarms/` — SNS topic + Lambda error alarms (all 5 functions) + API Gateway alarms (5xx, p99 latency, throttles)
- [x] 8 alarms total wired to `bbq-dev-alarms` SNS topic
- [x] SNS email subscription confirmed — alarm notifications delivered to jcarter82@gmail.com
- [x] All alarms provisioned via Terraform; no console clicks
- [x] Smoke tested: bad Lambda invocation triggered alarm within 5-minute window

**Definition of done:** At least one alarm fires and delivers email notification in dev. ✓ COMPLETE

---

### Saturday 2026-04-04 (Week 5 Housekeeping + Sprints 13)

**Housekeeping — OIDC permissions and infrastructure reconciliation:**

- [x] Fixed OIDC role: added SNS + CloudWatch Alarms permissions (PR #18) — unblocked terraform plan in CI
- [x] Fixed OIDC role: moved `cognito-idp:DescribeUserPoolDomain` to `CognitoGlobal` statement (requires `Resource: *`) — unblocked plan refresh
- [x] Fixed OIDC role: added `SNS:GetSubscriptionAttributes` + `SetSubscriptionAttributes` (PR #21) — unblocked subscription state refresh
- [x] Reconciled SNS email subscription into Terraform state via `terraform import` — subscription now fully managed by Terraform
- [x] Removed `alarm_notification_email = ""` from `infra/envs/dev/terraform.tfvars` — empty string was overriding `TF_VAR` env var (tfvars take precedence)
- [x] Moved `terraform apply` to GitHub Actions for all environments — dev apply now runs automatically on merge to main; no local apply for any environment (ADR 0002, CLAUDE.md updated)

**Sprint 13 — Python dependency scanning in CI:**

- [x] Created `app/requirements.txt` with `boto3==1.42.83` pinned for scanning (runtime-provided, not packaged)
- [x] Added `.github/workflows/python.yml` — Lint (ruff) + Dependency Scan (pip-audit) on `app/**` PRs
- [x] pip-audit fails on vulnerabilities with a fix available; `--no-deps` scans only explicitly listed packages
- [x] Gate verified: `requests==2.6.0` (5 known CVEs) correctly blocked PR #23; PR closed without merge

**Definition of done:** PRs fail CI if pip-audit finds a vulnerability with a fix available. ✓ COMPLETE

---

## Week 6 (2026-04-05 – 2026-04-11)

**Phase:** Phase 3 — Security Hardening (continued)

---

### Sunday 2026-04-05 (Sprint 14 — WAF module scaffold)

- [x] Created `infra/modules/waf/` — `main.tf`, `variables.tf`, `outputs.tf`
- [x] `enable_waf` variable (default false); module creates no resources when false
- [x] WAF WebACL resource with `scope = "REGIONAL"` (API Gateway)
- [x] Set `enable_waf = false` in dev tfvars; `enable_waf = true` in prod tfvars
- [x] `terraform plan` for dev shows no WAF resources; prod plan shows WebACL stub
- [x] Added 3 Checkov skip rules with justifications (CKV2_AWS_31, CKV_AWS_175, CKV_AWS_192)

**Definition of done:** WAF module exists; dev plan clean; prod plan shows WebACL resource. ✓ COMPLETE

---

### Monday 2026-04-06 (Sprint 15 — WAF rules + rate limit)

- [x] AWS managed rules: `AWSManagedRulesCommonRuleSet` + `AWSManagedRulesKnownBadInputsRuleSet`
- [x] Rate limit rule: 1000 requests / 5 minutes per IP
- [x] Associate WebACL with API Gateway stage when `enable_waf = true`
- [x] WAF CloudWatch logging added (`aws-waf-logs-bbq-prod`); resolves CKV2_AWS_31
- [x] Full prod infra wired (all Lambda, Cognito, DynamoDB, API, Alarms); log retention 90 days
- [x] 3 checkov skips removed — checks now pass natively
- [x] Prod plan: 64 to add, 0 to change, 0 to destroy

**Definition of done:** Prod plan shows full WAF WebACL with managed rules and rate limit; dev unaffected. ✓ COMPLETE

---

### Tuesday 2026-04-07 (Sprint 16 — Threat model)

- [x] Wrote `docs/03-threat-model.md` — assets, threats (rating stuffing, privilege escalation, injection, secrets exposure), mitigations mapped to actual controls
- [x] Updated `docs/04-cost-estimate.md` to include WAF ACL + rule costs (prod only)

**Definition of done:** Threat model committed; every major threat has a named control; cost estimate updated. ✓ COMPLETE

---

### Wednesday 2026-04-08 (Sprint 17 + housekeeping)

- [x] Added `IaC Security Scan (checkov)` as required status check in GitHub branch protection
- [x] Fixed WAF WebACL association — HTTP APIs not supported by WAFv2 `AssociateWebACL`; removed association resource; WAF re-association deferred to Sprint 22 via CloudFront (PR #29)
- [x] Reorganized `terraform.yml` — dev/prod grouped; checkov needs both plans; `.github/workflows/**` added to path triggers (PR #30)
- [x] Re-added CKV2_AWS_31 checkov skip — checkov version regression on count expression correlation
- [x] Prod apply clean end-to-end after PRs #28, #29, #30 merged

**Definition of done:** Prod apply succeeds; checkov is a required status check; CI triggers on workflow changes. ✓ COMPLETE

---

### Thursday 2026-04-10 (Sprint 19 — SSM audit + spike alarm)

- [x] Audited all Lambda `environment_vars` — all five functions carry DynamoDB table names only; no credentials, tokens, or keys
- [x] Documented SSM decision: not needed yet; designated for future secrets (API keys, SMTP, etc.); documented in threat model with trigger conditions
- [x] Added CloudWatch alarm on `POST /v1/ratings` invocation count spike — dev: 50/5 min, prod: 200/5 min

**Definition of done:** SSM decision documented; spike alarm deployed to dev. ✓ COMPLETE

---

### Friday 2026-04-11 (Sprint 20 — Structured logging audit)

- [x] Reviewed all 5 Lambda handlers (`health`, `get_restaurants`, `get_restaurant_detail`, `get_leaderboard`, `submit_rating`)
- [x] Fixed `requestId` across all handlers — now sourced from `event["requestContext"]["requestId"]` (API Gateway request ID, not Lambda context object)
- [x] Confirmed all handlers emit spec-compliant structured JSON: `level`, `message`, `requestId`, `userSub`, `route`, `statusCode`, `latencyMs`, `restaurantId` (where applicable) — no PII
- [x] Fix CI path filter — removed `paths:` filter from PR trigger so required status checks always run on every PR regardless of which files changed

**Definition of done:** All 5 handlers emit spec-compliant structured JSON logs. ✓ COMPLETE
