# ADR 0001: Stack Selection

## Status
Accepted

## Context

This project is a DevSecOps portfolio artifact. The stack must demonstrate production-grade cloud engineering while being deliverable in compressed time slots (M/W/F + Saturday). The app theme is a Memphis BBQ restaurant ranking platform.

Key requirements:
- User-submitted ratings with abuse controls
- Public-facing frontend
- Authentication required on all backend endpoints
- Infrastructure fully managed with IaC
- CI/CD with no long-lived credentials
- Dev and prod environment separation

## Decision

| Layer | Choice | Alternatives considered |
|---|---|---|
| Compute | AWS Lambda + API Gateway HTTP API | EC2/Node, ECS Fargate |
| Language | Python 3.12 | Node.js |
| Database | DynamoDB | RDS (Postgres/MySQL) |
| Auth | Amazon Cognito User Pools | Clerk, Auth0, roll-your-own JWT |
| Frontend | S3 + CloudFront | Netlify, Amplify |
| IaC | Terraform | AWS CDK, SAM |
| CI/CD | GitHub Actions + OIDC | Jenkins, CircleCI |
| Region | us-east-1 exclusively | Multi-region (out of scope) |

## Rationale

**Lambda over EC2:** The author's existing portfolio already includes an EC2/Node/RDS project. Serverless provides a distinct story, lower operational overhead, and fits "thin CRUD + auth + leaderboard" access patterns well. The live leaderboard is deferred to a later phase; the architecture is designed to accommodate it without a rewrite (polling now, DynamoDB Streams + push later).

**Python over Node:** Personal preference and familiarity. Lambda + Python is a common, well-supported combination.

**DynamoDB over RDS:** Leaderboard access patterns (fast ranked reads, keyed by user+restaurant) map naturally to DynamoDB. Eliminates connection management complexity under Lambda burst. `PAY_PER_REQUEST` billing is cost-effective for early traffic.

**Cognito over third-party:** AWS-native; integrates directly with API Gateway JWT authorizer. Free tier covers expected traffic. Avoids a third-party dependency for a core security control.

**Terraform over CDK/SAM:** IaC tool of choice for target roles (DevSecOps, cloud engineering). Demonstrates Terraform-specific skills (modules, remote state, backends, OIDC provider config).

**OIDC over static keys:** GitHub Actions assumes an IAM role via OIDC — no long-lived AWS credentials stored in GitHub Secrets. This is a primary portfolio signal.

**us-east-1 exclusively:** Simplifies networking, reduces latency variance, avoids multi-region complexity out of scope for this project.

## Consequences

- Cold starts are acceptable for a portfolio/demo app; latency targets are set accordingly.
- DynamoDB requires careful key design upfront; this is documented in `README.md` and `docs/roadmap.md`.
- Cognito Hosted UI is used for MVP; custom auth UI is optional future work.
- A `users` table is not needed — Cognito is the identity store; `sub` is the user key everywhere.
- Realtime leaderboard (WebSockets/AppSync) is explicitly out of scope for Phase 1–2 but the data model is designed to support it.
- WAF and GuardDuty are prod-only. Dev uses API Gateway throttling and Cognito auth for abuse protection. This keeps dev cost at ~$0 and reduces operational noise during development.
- SSM Parameter Store Standard is used for all secrets. Secrets Manager is not used — automatic rotation is not required for this project.
