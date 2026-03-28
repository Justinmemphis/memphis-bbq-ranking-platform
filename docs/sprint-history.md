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
