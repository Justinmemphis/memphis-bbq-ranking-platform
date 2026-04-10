# Threat Model v1

Memphis BBQ Ranking Platform — Phase 3 Security Hardening

**Date:** 2026-04-07
**Scope:** Current dev environment as deployed. Controls marked **[prod-only]** are active in prod but not dev.
**Not in scope:** Physical security, AWS account compromise, supply-chain attacks on AWS itself.

---

## Assets

| Asset | Sensitivity | Why it matters |
|---|---|---|
| User identity (Cognito sub, email) | High | PII; compromise enables impersonation |
| Rating data (who rated what, score) | Medium | Manipulation changes leaderboard outcomes; audit log is the recovery path |
| Leaderboard snapshot | Medium | Public-facing; stuffing or manipulation is reputation damage |
| Restaurant data | Low | Read-heavy; no PII; loss is inconvenient but not a breach |
| AWS credentials / IAM | Critical | Compromise = full account access |
| Lambda environment variables | Low | Contain DynamoDB table names only — not credentials or sensitive config; audited 2026-04-10 |

---

## Threat Surface Summary

The primary risk surface is **user-submitted content**: any authenticated user can call `POST /v1/ratings`. The auth boundary (Cognito → API Gateway JWT authorizer → Lambda) is the first line of defense. WAF is the second. Application-layer validation is the third.

Secondary surface: **IAM and secrets** — Lambda execution roles, SSM parameters, GitHub Actions OIDC role.

---

## Threat 1: Rating Stuffing / Leaderboard Manipulation

**Scenario:** An attacker creates multiple Cognito accounts (or controls one account) and submits many ratings for a target restaurant to inflate or suppress its rank.

**Attack vectors:**
- Multiple legitimate accounts voting in coordination (Sybil attack)
- Automated script using a valid JWT to spam `POST /v1/ratings`
- Credential stuffing against Cognito Hosted UI to take over real accounts

**Controls in place:**

| Control | Where | Effectiveness |
|---|---|---|
| One rating per user per restaurant | DynamoDB PK+SK upsert (`ratings` table: PK=`user_id`, SK=`restaurant_id`) | Eliminates duplicate votes from a single account |
| `sub` as identity key | `shared/auth.py` — extracted from JWT claims, not request body | Caller cannot forge another user's `sub` |
| Per-IP rate limit: 1000 req / 5 min | WAF `RateLimitPerIP` rule **[prod-only]** | Blocks automated flooding from a single IP |
| AWS Managed Rules (CommonRuleSet) | WAF **[prod-only]** | Blocks HTTP anomalies and malformed requests used by bots |
| `rating_events` audit log | `submit_rating` — append-only write on every submission | Provides post-incident forensics; allows score recalculation after removing fraudulent ratings |
| Bayesian average ranking | `_recompute_leaderboard()` in `submit_rating` | New restaurants and low-count restaurants regress toward the mean (C=5, m=3); single-vote manipulation has diminished impact |
| Structured logs with `userSub` | All Lambdas → CloudWatch | Enables correlation of submissions to a specific identity for abuse investigation |

**Residual risks:**
- No per-user rate limit — a single account could spam updates (WAF rate limits by IP, not JWT sub). Mitigation: per-user rate limiting deferred to Phase 4 (Lambda@Edge) and application layer (planned).
- No new-account throttle — a fresh account can immediately submit ratings. Planned for Phase 3.
- Coordinated multi-account attacks (many IPs, one account each) are not blocked by IP rate limits. Bayesian dampening provides partial mitigation.
- No CAPTCHA on the Cognito Hosted UI.

---

## Threat 2: Privilege Escalation

**Scenario:** A regular user accesses admin routes, reads another user's private data, or performs actions only admins should be allowed to do.

**Attack vectors:**
- Calling an admin endpoint without admin Cognito group membership
- Forging or replaying a JWT with modified claims
- Accessing another user's rating data by guessing their `sub`

**Controls in place:**

| Control | Where | Effectiveness |
|---|---|---|
| JWT authorizer on all `/v1/` routes | API Gateway HTTP API — validates issuer, audience, and signature | Unsigned or tampered JWTs are rejected at the API layer before Lambda is invoked |
| `sub` sourced from JWT claims (not body) | `shared/auth.py:get_user_sub()` | A caller cannot set or override their own `sub` |
| Each environment has its own Cognito User Pool | Terraform `cognito` module | Dev tokens cannot be used against prod endpoints |
| IAM least-privilege per Lambda | Lambda execution roles scoped to only the tables each function needs | A compromised `get_restaurants` Lambda cannot write to `ratings` |
| No `users` table | Architecture decision | There is no user lookup table to enumerate or exfiltrate |

**Residual risks:**
- Admin group + route guard not yet implemented. Admin endpoints (`/v1/admin/`) are planned but not deployed. Until implemented, there are no admin routes to protect — but this must be in place before any admin functionality ships.
- The `rating_events` table stores `user_id` (Cognito sub) + score. A compromised Lambda role with Scan permission could enumerate all user activity. Mitigation: IAM is scoped to minimum required actions; no Lambda has broad Scan rights by default.

---

## Threat 3: Injection

**Scenario:** An attacker injects malicious content via user-supplied fields to manipulate data, exfiltrate information, or exploit downstream systems.

**Attack vectors:**
- NoSQL injection via `restaurant_id` or `score` in the rating request body
- XSS via restaurant names or other text stored in DynamoDB and rendered in the frontend
- Log injection — crafted strings that pollute or forge structured log entries
- Log4Shell / JNDI injection via HTTP headers (historical CVE; API Gateway access logs could relay headers to downstream log analysis)

**Controls in place:**

| Control | Where | Effectiveness |
|---|---|---|
| Input validation: score must be int in [1,5] | `submit_rating/handler.py:handler()` | Rejects non-numeric and out-of-range scores before any DB write |
| Input validation: `restaurant_id` must be non-empty string | `submit_rating/handler.py:handler()` — `.strip()` + length check | Rejects blank or whitespace-only identifiers |
| Restaurant existence check before write | `submit_rating` — `GetItem` on `restaurants` table | Prevents ratings for arbitrary IDs that could surface on the leaderboard |
| Extra request body keys silently ignored | `body.get(key)` pattern — only named fields are read | No unintended fields reach DynamoDB |
| DynamoDB API (not SQL) | Architecture | No SQL injection surface; DynamoDB operations are parameterized by design |
| AWS Managed Rules — CommonRuleSet | WAF **[prod-only]** | Blocks SQLi, XSS, path traversal, HTTP anomalies at the edge |
| AWS Managed Rules — KnownBadInputsRuleSet | WAF **[prod-only]** | Blocks Log4Shell (`${jndi:...}`) and Spring4Shell payload patterns in headers and body |
| Structured JSON logs (no user-supplied values interpolated into log strings) | All Lambdas | Log entries serialize values as JSON fields — injection via crafted input does not forge log structure |

**Residual risks:**
- Frontend rendering: if the admin UI or public UI renders unescaped DynamoDB string values (e.g., restaurant names), XSS becomes possible. This is a frontend concern — the current Lambdas return data as JSON; XSS is only possible if the rendering layer is unsafe. Must be enforced in the UI implementation (Phase 3).
- Comment fields or free-text ratings are not yet in the data model. If added, additional sanitization and output encoding will be required.

---

## Threat 4: Secrets Exposure

**Scenario:** AWS credentials, Cognito client secrets, or other sensitive config values are leaked via code, logs, environment variables, or the GitHub repository.

**Attack vectors:**
- Hardcoded secrets in Terraform files or Python source code committed to GitHub
- Lambda environment variables logged or exposed via a misconfigured endpoint
- Long-lived AWS access keys stored in GitHub Actions secrets
- Over-privileged IAM role assumed by GitHub Actions

**Controls in place:**

| Control | Where | Effectiveness |
|---|---|---|
| No static AWS credentials anywhere | Architecture — GitHub Actions uses OIDC; no IAM access keys exist | Eliminates the most common credential leak vector |
| GitHub Actions OIDC role scoped to this repo + branch | `infra/` OIDC trust policy | A compromised GitHub token from another repo cannot assume this role |
| Lambda env vars contain only non-secret config (table names) | Terraform `lambda` module — audited 2026-04-10 | No credentials, tokens, or Cognito client secrets are in env vars; table names are not sensitive |
| SSM Parameter Store Standard designated for all future secrets | Architecture decision — no secrets exist to store yet | When third-party API keys, SMTP credentials, or other sensitive config are needed, they go to SSM; Lambda IAM role gets `ssm:GetParameter` scoped to specific parameter paths |
| Structured logs exclude PII and secrets | Log field schema: `level, message, requestId, userSub, route, statusCode, latencyMs, restaurantId` | No tokens, emails, or scores appear in CloudWatch logs |
| `.gitignore` excludes `*.tfvars` local overrides, `.env` files | Repo config | Prevents accidental commit of local credential overrides |
| IaC security scanning (Checkov) in CI | `.github/workflows/terraform.yml` | Blocks PRs that introduce Checkov-detected misconfigurations (e.g., unencrypted resources, logging disabled) |

**SSM decision (audited 2026-04-10):** All five Lambda functions (`health`, `get_restaurants`, `get_restaurant_detail`, `get_leaderboard`, `submit_rating`) carry only DynamoDB table names in `environment_vars`. No credentials, API keys, or Cognito client secrets exist in env vars or anywhere in the codebase. SSM Parameter Store is the designated mechanism for future secrets; it is not currently in use because there are no secrets to store. SSM becomes necessary when: (1) a third-party API key is added (e.g., Google Places enrichment), (2) SMTP credentials are needed for notifications, or (3) a Cognito client secret is used (current setup uses a public client). At that point, a `ssm:GetParameter` policy scoped to the specific parameter path is added to the relevant Lambda's execution role.

**Residual risks:**
- Lambda environment variables are visible to anyone with `lambda:GetFunctionConfiguration` IAM permission. Table names are not secrets, but this surface should be reviewed if the data model changes (e.g., adding auth tokens or connection strings as env vars).
- SSM Parameter Store Standard tier does not support automatic rotation. If a secret requires rotation, Secrets Manager is the correct tool. No current secrets require rotation.
- KMS encryption for DynamoDB tables and CloudWatch log groups is not yet enabled (Checkov skips `CKV_AWS_119`, `CKV_AWS_158` — planned for Phase 3 completion). Data at rest is protected by AWS default encryption but not customer-managed keys.

---

## Control Coverage Matrix

| Threat | Edge (WAF) | Auth (Cognito/JWT) | App Layer | Audit / Detection |
|---|---|---|---|---|
| Rating stuffing | Per-IP rate limit [prod] | One rating/user/restaurant (sub from JWT) | Score + restaurant_id validation | `rating_events` audit log; structured logs; submit_rating invocation spike alarm |
| Privilege escalation | — | JWT authorizer; per-env User Pools | Admin group guard (planned) | CloudWatch Lambda error alarms |
| Injection | CommonRuleSet + KnownBadInputs [prod] | — | Input validation; DynamoDB parameterized API | Structured logs; WAF sampled request logs |
| Secrets exposure | — | OIDC; no static keys | SSM for secrets; no PII in logs | Checkov CI gate; CloudWatch alarms |

---

## Out of Scope for This Version

- **DDoS at scale:** WAF rate limits provide basic protection; AWS Shield Standard covers volumetric L3/L4 attacks automatically. Shield Advanced is not in scope for this portfolio project.
- **GuardDuty:** Threat detection for anomalous API calls and compromised credentials. Planned for Phase 4 (prod only).
- **Account takeover on Cognito Hosted UI:** No CAPTCHA or advanced MFA currently. Cognito provides basic brute-force throttling; advanced bot protection requires WAF + Cognito integration (deferred).
- **Supply chain attacks:** Python dependency scanning (`pip-audit`) runs in CI (added Sprint 13). Terraform provider pinning is in place.

---

## Open Items (Phase 3 Remainder)

| Item | Sprint | Status |
|---|---|---|
| Admin Cognito group + `/v1/admin/` route guard | Week 7 deep work | Planned |
| Admin UI (S3 + CloudFront) | Week 7 deep work | Planned |
| Per-user rate limiting (Lambda@Edge on JWT sub) | Phase 4 | Deferred |
| New-account submission throttle | Phase 3 | Planned |
| CloudWatch alarm on rating submission spikes | Sprint 19 | Complete — dev: 50 invocations/5 min; prod: 200 invocations/5 min |
| DynamoDB KMS CMK encryption | Phase 3 | Planned (Checkov skip documented) |
| GuardDuty | Phase 4, prod only | Planned |
