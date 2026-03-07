# AWS Cost Estimate

Memphis BBQ Ranking Platform — Portfolio / Very Low Usage

**Assumptions:**
- ~100 API requests/day (~3,000/month)
- ~10 active users
- ~50 restaurants in the database
- Dev environment torn down between work sessions when possible
- All resources in us-east-1
- AWS free tier not applicable

---

## Phase-by-Phase Estimate

### Phase 0–2: Core Infrastructure + App (no WAF, no GuardDuty)

| Service | Usage | Monthly Cost |
|---|---|---|
| **Lambda** | 3,000 invocations/month, ~200ms avg, 128 MB | ~$0.00 ($0.20/1M requests + $0.0000166667/GB-sec; negligible at this volume) |
| **API Gateway HTTP API** | 3,000 requests/month | ~$0.00 ($1.00/1M requests) |
| **DynamoDB** | PAY_PER_REQUEST; ~3K writes + 10K reads/month; <1 MB storage | ~$0.00 ($1.25/1M writes, $0.25/1M reads; $0.25/GB storage) |
| **S3** | ~10 MB frontend assets; reads served via CloudFront | ~$0.00 ($0.023/GB storage; minimal PUT/GET requests) |
| **CloudFront** | Low traffic; static frontend only | ~$0.00 ($0.0085/10K HTTPS requests; negligible at this volume) |
| **Cognito User Pools** | <10 MAUs, direct sign-in | $0.00 (direct sign-in MAUs are free up to 50K regardless of free tier) |
| **CloudWatch Logs** | JSON logs, dev 14-day retention, prod 60-day retention | ~$0.05–0.25/month ($0.50/GB ingested; low volume) |
| **CloudWatch Alarms** | 2–3 alarms | ~$0.30/month ($0.10/alarm/month) |
| **SSM Parameter Store** | Standard parameters for config/secrets | $0.00 (Standard tier has no per-parameter charge) |
| **S3 (Terraform state)** | Tiny state files; minimal requests | ~$0.00 |
| **DynamoDB (TF lock table)** | Near-zero usage | ~$0.00 |

**Phase 0–2 estimated total: ~$0.50–1.00/month**

---

### Phase 3: Security Hardening (adds WAF)

| Service | Added/Changed | Monthly Cost |
|---|---|---|
| **AWS WAF** | 1 Web ACL on CloudFront; AWS Managed Rule Groups (free); ~3K requests/month | **~$5.00/month** (Web ACL: $5/month; requests negligible at this volume) |
| **Secrets Manager** | Optional: only if rotation is required | **$0.40/secret/month** — use SSM Standard instead where rotation is not needed |

**Phase 3 estimated addition: ~$5.00/month**
**Phase 3 cumulative total: ~$5.50–6.00/month**

> WAF is the first meaningful cost in this architecture. It earns its place as a portfolio signal (rate limiting, OWASP managed rules, CloudFront integration). To minimize cost during development, attach WAF only to prod CloudFront; omit from dev.

> **Recommendation:** Use SSM Parameter Store Standard (no per-parameter charge) for all secrets unless automatic rotation is required. Secrets Manager adds $0.40/secret/month and is justified only when rotation is needed.

---

### Phase 4: Operability + GuardDuty

| Service | Added/Changed | Monthly Cost |
|---|---|---|
| **GuardDuty** | Threat detection; analyzes CloudTrail + VPC flow logs + DNS | **~$1–3/month** at low activity |
| **DynamoDB Streams** | If enabled for leaderboard recompute | ~$0.00 at low volume ($0.02 per 100K stream read units) |
| **SNS** | Alarm notifications to email | ~$0.00 ($0.50/1M publishes; negligible) |
| **AWS Budgets** | Cost alerts | $0.02/budget/month (first 2 are $0.02 each) |

**Phase 4 estimated addition: ~$1–3/month**
**Phase 4 cumulative total: ~$6–9/month**

---

## Summary by Phase

| Phase | Cumulative Monthly Estimate |
|---|---|
| Phase 0–2 (core infra + app) | ~$0.50–1.00 |
| Phase 3 (security hardening) | ~$5.50–6.00 |
| Phase 4 (ops + GuardDuty) | ~$6.50–9.00 |
| Phase 5 (portfolio polish) | ~$6.50–9.00 (no new services) |

**Estimated annual cost (full project running):** ~$78–108/year

---

## Cost Controls (implemented as part of Phase 4)

- [ ] AWS Budget: alert at $10/month and $20/month
- [ ] CloudWatch alarm on estimated charges
- [ ] Log retention enforced in Terraform (dev: 14 days, prod: 60 days)
- [ ] DynamoDB PAY_PER_REQUEST — no cost when idle
- [ ] Lambda — no cost when idle
- [ ] Teardown runbook: `terraform destroy` on dev environment between extended work pauses

---

## Dev vs Prod Cost Split

For services that charge per resource (not per request), running both dev and prod doubles the cost:

| Service | Dev | Prod | Notes |
|---|---|---|---|
| WAF Web ACL | $5/month | $5/month | Omit from dev to save $5/month |
| GuardDuty | $1–3/month | $1–3/month | Enable only in prod for portfolio purposes |
| CloudWatch Alarms | ~$0.30/month | ~$0.30/month | Small; acceptable to run in both |
| Everything else | ~$0 | ~$0 | Request-based; negligible at this volume |

**Recommendation:** Attach WAF only to the prod CloudFront distribution. Dev relies on API Gateway throttling and Cognito auth for abuse protection during development.

---

## What Would Change These Estimates

| Change | Impact |
|---|---|
| Custom domain (Route 53 hosted zone) | +$0.50/month |
| Secrets Manager for all secrets (3 secrets) | +$1.20/month |
| RDS instead of DynamoDB | +$15–25/month minimum (db.t3.micro, always-on) |
| ECS Fargate instead of Lambda | +$10–30/month (task running continuously) |
| Traffic spike (100x — 300K req/month) | Still ~$1–2/month additional; serverless scales cheaply |
| Multi-region deployment | Roughly 2x for duplicated resources |
| CloudWatch custom dashboards (more than 3) | $3/dashboard/month |
| X-Ray tracing | $5.00/1M traces recorded; negligible at low volume |
