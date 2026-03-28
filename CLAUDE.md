# Claude Code Rules for This Project

## Terraform

- Claude may run `terraform init` and `terraform plan` freely.
- **Only the user runs `terraform apply`.** Claude must never run `terraform apply` under any circumstance, even if asked or if it appears safe.
- Always present plan output for review before suggesting the user run apply.

## Git / GitHub

- Claude may run `git add` and `git commit`.
- **Only the user runs `git push`.** Claude must never push to the remote repository.
- The user manually reviews all GitHub pull requests and merges. Claude should not attempt to open, merge, or close PRs.
- **Any change under `infra/` must go through a PR** — never commit directly to main for infrastructure changes. Branch → PR → plan runs → merge → apply.

## How Claude Should Assist on This Project

The user owns architecture decisions, security reasoning, and verification. Claude accelerates implementation. This is a career-development project — the user must be able to explain and defend every decision.

**Claude's role (do these):**
- Implement what the user specifies; scaffold boilerplate, modules, workflows, tests, docs
- When writing any non-trivial block, annotate it with: what it does, why it's designed this way, security implications, and alternatives considered
- When presenting multiple approaches, compare tradeoffs across cost, security, and complexity
- Flag anything touching IAM, networking/security groups, auth, data deletion, or billing for explicit user verification before proceeding
- After generating Terraform, prompt the user to run: `terraform fmt`, `terraform validate`, `tflint`, and review `terraform plan` line-by-line

**Claude must not:**
- Make architecture or data model decisions without the user's explicit input
- Skip annotations on security-relevant code to save space
- Silently assume an approach is safe — call out known sharp edges and AWS limitations

**Expected workflow per task:**
1. User writes a mini-spec (inputs, outputs, constraints, definition of done)
2. Claude implements with inline annotations
3. User runs the verification checklist
4. User rewrites the "why" in their own words for README/docs

## Modern SDLC Principles

This project follows modern SDLC practices as a deliberate career-development exercise.

**Branching:**
- All work happens on feature branches (e.g., `feature/terraform-foundation`, `fix/auth-claims`)
- No direct commits to `main` — all changes go through a PR
- CI must pass before a PR can be merged
- **Exception:** doc-only changes (no code, no `infra/` files) may be committed directly to `main`

**Definition of done (per feature/task):**
- Code deployed to dev environment
- Basic test or smoke check passing
- Relevant docs updated in the same session

**CI gates (must pass before merge):**
- `terraform fmt -check` + `terraform validate`
- Python linting (ruff or flake8)
- Unit tests
- IaC security scan (tfsec/checkov) — added in Phase 3

**Release tagging:**
- Prod deployments are tagged with semver (e.g., `v0.1.0`)
- Tag message summarizes what changed

**ADRs:**
- Significant architectural decisions get an ADR in `docs/adr/`
- Format: context → decision → rationale → consequences
- One page maximum

**Vertical slices:**
- Every PR delivers something observable — a working endpoint, a deployed resource, a passing test
- No "big bang" PRs that touch everything at once

## Command Formatting

When presenting shell commands to the user:
- **Always use true single-line commands** — no backslash continuations, no heredocs, no wrapping.
- For multi-step sequences that share variables (e.g. TOKEN), present each step as a separate single-line command. Variables persist in the zsh session between pastes.
- For genuinely complex scripts (more than ~3 steps), write a `.sh` file using the Write tool and tell the user to run `bash <filename>`. Do not inline complex scripts as shell commands.

## General Workflow Reminders

- Follow modern DevSecOps principles: Infrastructure as Code, least privilege, no long-lived secrets, security as a first-class concern.
- Prefer small, vertical slices of work that are deployable and testable independently.
- Document architecture decisions in `docs/adr/` as ADR files.
- Keep docs current — update them in the same session as the related code change.
- When a design decision adds, removes, or changes an AWS service, update `docs/04-cost-estimate.md` in the same session.
