# ADR 0002 — CI-Only Terraform Apply for All Environments

## Context

Initially, `terraform apply` for the dev environment was run manually by the developer using local AWS credentials. The plan was to add CI-based apply for prod only once that environment was provisioned.

As the project progressed, it became clear that running apply locally — even for dev — undermines the portfolio signal the project is trying to demonstrate. A production-grade DevSecOps posture means no human should be able to change AWS infrastructure outside of a reviewed, auditable pipeline.

Additionally, the OIDC-based GitHub Actions role was already scoped for both plan and apply operations. The infrastructure to support CI apply was already in place.

## Decision

All `terraform apply` operations for all environments (dev and prod) run exclusively in GitHub Actions via OIDC, triggered automatically on merge to main when `infra/**` paths change. No local apply is permitted for any environment.

The workflow is:
1. Feature branch → PR opens → `plan-dev` + `checkov` jobs run (gating merge)
2. PR merged to main → `apply-dev` job runs automatically
3. Prod apply will follow the same pattern when prod environment is provisioned

## Rationale

- **Audit trail** — every apply is tied to a merge commit and logged in GitHub Actions
- **No credential sprawl** — developers never need AWS credentials with write access locally
- **Consistency** — dev and prod follow identical apply mechanics; issues surface in dev first
- **Stronger portfolio signal** — demonstrates that infrastructure changes require a reviewed PR, not just terminal access
- **OIDC already in place** — the trust chain was already built; extending it to apply required only a workflow change

## Consequences

- `ALARM_NOTIFICATION_EMAIL` must be stored as a GitHub Actions secret in the `dev` environment (and `prod` when provisioned), replacing the local `TF_VAR_alarm_notification_email` env var
- Developers can still run `terraform plan` locally for fast feedback during development
- Any emergency break-glass procedure (e.g. a rollback during an incident) must go through a PR or a manual `workflow_dispatch` trigger — not local apply
- CLAUDE.md updated: "terraform apply is only ever run by GitHub Actions"
