# Claude Code Rules — Memphis BBQ Ranking Platform

## Hard Rules

**Terraform:**
- Claude may run `terraform init` and `terraform plan` freely.
- `terraform apply` is CI-only — never locally, never by Claude.
- Any change under `infra/` must go through a PR.

**Git / GitHub:**
- Claude may run `git add`, `git commit`, `git push`, and `gh pr create`.
- Only the user approves and merges PRs.
- Doc-only changes (no code, no `infra/` files) may commit directly to main.

## Project Identity

Memphis BBQ Ranking Platform. The app is BBQ; the portfolio signal is production-grade cloud security engineering. AWS (us-east-1), Terraform, Python Lambda, API Gateway, DynamoDB, Cognito, S3 + CloudFront.

Naming: `${app}-${env}-${resource}`. Environments: `dev`, `prod`. Single AWS account.

## Stack

- Frontend: S3 + CloudFront
- Backend: Lambda (Python) + API Gateway HTTP API
- Auth: Cognito User Pools; JWT authorizer; `sub` from `event["requestContext"]["authorizer"]["jwt"]["claims"]["sub"]`
- DB: DynamoDB — tables: `restaurants`, `ratings` (PK: user_id, SK: restaurant_id), `rating_events`, `leaderboard_snapshot`
- IaC: Terraform (modules in `infra/modules/`, envs in `infra/envs/`)
- CI/CD: GitHub Actions + OIDC (no static keys)

## How Claude Assists

This is a career-development project. The user owns architecture decisions and must be able to explain every choice.

**Do:**
- Implement what the user specifies
- Annotate non-trivial blocks: what it does, why, security implications, alternatives considered
- Compare approaches across cost, security, and complexity when multiple options exist
- Flag anything touching IAM, networking, auth, data deletion, or billing before proceeding
- After generating Terraform: prompt user to run `terraform fmt`, `terraform validate`, `tflint`, review plan

**Don't:**
- Make architecture or data model decisions without explicit user input
- Skip annotations on security-relevant code to save space
- Silently assume an approach is safe

## Workflow: Subagents + Skills

Use the agents and skills in `.claude/` to keep the main conversation clean.

**Agents** (`.claude/agents/`):
- `@planner` — decompose a task before touching code (read-only)
- `@implementer` — write code and Terraform following the plan
- `@reviewer` — review changes for correctness, security, test gaps (read-only)

**Skills** (invoke with `/`):
- `/implement-feature <description>` — full feature implementation loop
- `/review-security [scope]` — security-focused review (runs in forked subagent)
- `/trace-bug <symptom>` — root-cause investigation (runs in forked subagent)
- `/ship-pr` — stage, commit, draft PR description

**Typical workflow:**
1. Ask `@planner` to break down the task
2. Run `/implement-feature` or ask `@implementer` directly
3. Run `/review-security` or ask `@reviewer` on changed files
4. Run `/ship-pr` to prepare the commit and PR

## IAM Policy Rules

- Scope permissions to specific resource ARNs where possible
- When `Resource: "*"` is required, comment: why it's needed and that it's an AWS limitation
- Each new IAM statement gets a sprint/task reference and explanation
- No `Action: "*"` ever

## Logging Rules

JSON structured logs only. Allowed fields: `level`, `message`, `requestId`, `userSub`, `route`, `statusCode`, `latencyMs`, `restaurantId`. No PII.

## ADRs

Significant architectural decisions get an ADR in `docs/adr/`. Format: context → decision → rationale → consequences. One page max.

## Command Formatting

- Single-line commands only — no backslash continuations
- Multi-step sequences: one command per line; variables persist in zsh
- Complex scripts (3+ steps): write a `.sh` file, tell user to run `bash <filename>`
