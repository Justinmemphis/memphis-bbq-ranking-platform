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
