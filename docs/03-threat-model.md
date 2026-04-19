# Threat Model v2

Memphis BBQ Ranking Platform — Phase 3 Security Hardening

**Date:** 2026-04-19
**Scope:** Dev and prod environments as deployed through Sprint 25. Controls marked **[prod-only]** are active in prod but not dev.
**Not in scope:** Physical security, AWS account compromise, supply-chain attacks on AWS itself.

**What changed from v1 (2026-04-07):**
- Admin group guard deployed (`admin` Cognito group + server-side `AdminListGroupsForUser` check)
- Admin routes live: `/v1/admin/health`, `/v1/admin/users`, `/v1/admin/users/{sub}/action`, `/v1/admin/audit-log`
- Admin UI deployed to S3 + CloudFront (`/admin/index.html`) with Hosted UI implicit flow
- WAF re-scoped from REGIONAL to CLOUDFRONT — WebACL now associated with the CloudFront distribution
- All open items from v1 resolved (except per-user rate limiting, new-account throttle, and DynamoDB KMS CMK — deferred)

---

## Assets

| Asset | Sensitivity | Why it matters |
|---|---|---|
| User identity (Cognito sub, email) | High | PII; compromise enables impersonation |
| Rating data (who rated what, score) | Medium | Manipulation changes leaderboard outcomes; audit log is the recovery path |
| Leaderboard snapshot | Medium | Public-facing; stuffing or manipulation is reputation damage |
| Restaurant data | Low | Read-heavy; no PII; loss is inconvenient not a breach |
| AWS credentials / IAM | Critical | Compromise = full account access |
| Lambda environment variables | Low | Contain DynamoDB table names + Cognito User Pool IDs only — not credentials or secrets |
| Admin UI session tokens | High | Stored in sessionStorage; grant access to admin API routes; expire in 60 min |

---

## Threat Surface Summary

The primary risk surface is **user-submitted content**: any authenticated user can call `POST /v1/ratings`. The auth boundary (Cognito → API Gateway JWT authorizer → Lambda) is the first line of defense. WAF (CLOUDFRONT scope, prod-only) is the second. Application-layer validation is the third.

Secondary surface: **admin operations** — four `/v1/admin/` routes that can disable users, reset passwords, and read the rating audit log. Each route independently verifies admin group membership server-side.

Tertiary surface: **IAM and secrets** — Lambda execution roles, SSM parameters, GitHub Actions OIDC role.

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
| One rating per user per restaurant | DynamoDB PK+SK upsert (`ratings`: PK=`user_id`, SK=`restaurant_id`) | Eliminates duplicate votes from a single account |
| `sub` as identity key | `shared/auth.py:get_user_sub()` — from JWT claims, not request body | Caller cannot forge another user's `sub` |
| Per-IP rate limit: 1000 req / 5 min | WAF `RateLimitPerIP` rule — CLOUDFRONT scope **[prod-only]** | Blocks automated flooding from a single IP |
| AWS Managed Rules (CommonRuleSet) | WAF — CLOUDFRONT scope **[prod-only]** | Blocks HTTP anomalies and malformed requests used by bots |
| AWS Managed Rules (KnownBadInputsRuleSet) | WAF — CLOUDFRONT scope **[prod-only]** | Blocks Log4Shell and exploit delivery patterns in headers/body |
| `rating_events` audit log | `submit_rating` — append-only write on every submission | Provides post-incident forensics; queryable via `GET /v1/admin/audit-log` |
| Audit log endpoint | `admin_audit_log` Lambda — `GET /v1/admin/audit-log?restaurant_id=X` | Admin can query all rating events for a restaurant; useful for abuse investigation |
| Bayesian average ranking | `_recompute_leaderboard()` in `submit_rating` | New and low-vote restaurants regress toward the mean (C=5, m=3); single-vote manipulation has diminished impact |
| Rating spike alarm | CloudWatch — 50 invocations/5 min dev; 200/5 min prod | Triggers SNS alert when submission volume spikes unexpectedly |
| Structured logs with `userSub` | All Lambdas → CloudWatch | Enables correlation of submissions to a specific identity for abuse investigation |

**Residual risks:**
- No per-user rate limit — a single account could submit updates repeatedly (WAF rate limits by IP, not JWT sub). Per-user limiting deferred to Phase 4 (Lambda@Edge or application layer).
- No new-account submission throttle — a fresh Cognito account can immediately submit ratings. Deferred.
- Coordinated multi-account attacks (many IPs, one account each) are not blocked by IP rate limits. Bayesian dampening provides partial mitigation.
- No CAPTCHA on the Cognito Hosted UI sign-up page.

---

## Threat 2: Privilege Escalation

**Scenario:** A regular user accesses admin routes, reads another user's private data, or performs actions only admins should be allowed to do.

**Attack vectors:**
- Calling an admin endpoint without admin Cognito group membership
- Forging or replaying a JWT with modified group claims
- Accessing another user's rating data by guessing their `sub`
- An admin disabling other admins to lock them out

**Controls in place:**

| Control | Where | Effectiveness |
|---|---|---|
| JWT authorizer on all `/v1/` routes | API Gateway — validates issuer, audience, and signature | Unsigned or tampered JWTs are rejected before Lambda is invoked |
| `sub` sourced from JWT claims (not body) | `shared/auth.py:get_user_sub()` | A caller cannot set or override their own `sub` |
| Server-side admin group check | `shared/auth.py:is_admin()` — calls `cognito-idp:AdminListGroupsForUser` at request time | Group check is authoritative (not a stale JWT claim); verifies membership as it stands when the request arrives |
| Admin group guard on all `/v1/admin/` routes | `admin_health`, `admin_list_users`, `admin_manage_user`, `admin_audit_log` — each independently calls `is_admin()` | No admin route trusts a client-side claim; every route does its own check |
| Admin IAM: least-privilege per function | Each admin Lambda role is scoped to the exact Cognito operations it requires | `admin_list_users` cannot call `AdminDisableUser`; `admin_audit_log` cannot call `ListUsers` |
| Self-disable prevention | `admin_manage_user` — rejects `action=disable` when `target_sub == caller_sub` | An admin cannot accidentally lock themselves out; a second admin must disable them |
| Each environment has its own Cognito User Pool | Terraform `cognito` module | Dev admin accounts cannot affect prod; dev tokens are invalid against prod endpoints |
| IAM least-privilege per Lambda | Lambda execution roles scoped to only the tables/resources each function needs | A compromised `get_restaurants` Lambda cannot write to `ratings` |
| No `users` table | Architecture | There is no user lookup table to enumerate or exfiltrate |

**Residual risks:**
- Admin UI uses the Cognito implicit flow (tokens in URL hash after redirect). Tokens are stored in `sessionStorage` (cleared on tab close). A stolen access token (e.g., from a logged browser extension) could be used to call admin API endpoints until expiry (60 min). Mitigation: short token lifetime; server-side group check on every request.
- The `rating_events` table stores `user_id` (sub) + score. The `admin_audit_log` Lambda can read these. Admin access is intentional, but it means admins can see which users rated which restaurants. This is a documented, intentional access for operational abuse investigation — not an escalation.

---

## Threat 3: Injection

**Scenario:** An attacker injects malicious content via user-supplied fields to manipulate data, exfiltrate information, or exploit downstream systems.

**Attack vectors:**
- NoSQL injection via `restaurant_id` or `score` in the rating request body
- XSS via free-text content rendered in the admin UI
- Log injection — crafted strings that pollute structured log entries
- Log4Shell / JNDI injection via HTTP headers

**Controls in place:**

| Control | Where | Effectiveness |
|---|---|---|
| Input validation: score must be int in [1,5] | `submit_rating/handler.py` | Rejects non-numeric and out-of-range scores before any DB write |
| Input validation: `restaurant_id` must be non-empty string | `submit_rating/handler.py` — `.strip()` + length check | Rejects blank identifiers |
| Restaurant existence check before write | `submit_rating` — `GetItem` on `restaurants` | Prevents ratings for arbitrary IDs |
| `restaurant_id` from query param — exact key match | `admin_audit_log` — DynamoDB Query by PK | Query is parameterized; `restaurant_id` cannot alter query logic |
| Action allowlist in `admin_manage_user` | `ALLOWED_ACTIONS = {"disable", "enable", "force_reset"}` | No arbitrary Cognito API calls possible through this endpoint |
| DynamoDB API (not SQL) | Architecture | No SQL injection surface; all DynamoDB operations are parameterized by design |
| AWS Managed Rules — CommonRuleSet | WAF — CLOUDFRONT scope **[prod-only]** | Blocks SQLi, XSS, path traversal, HTTP anomalies at the edge |
| AWS Managed Rules — KnownBadInputsRuleSet | WAF — CLOUDFRONT scope **[prod-only]** | Blocks Log4Shell (`${jndi:...}`) payload patterns in headers and body |
| Structured JSON logs (no user-supplied values in format strings) | All Lambdas | `json.dumps({...})` — values are JSON fields, not interpolated into log format strings |
| Admin UI uses `textContent` / DOM manipulation (not `innerHTML`) | `admin.js` template literals | Restaurant names and user emails rendered as text content only; XSS not possible via DOM injection in the current implementation |

**Residual risks:**
- Admin UI renders `email`, `sub`, and `event` fields from API responses. If a future admin API field contains HTML and is rendered via `innerHTML`, XSS becomes possible. Current implementation uses template literals which pass values through as-is in `innerHTML`. This should be reviewed if new text fields are added to the admin UI.
- Free-text rating comments are not in the data model yet. If added, output encoding must be enforced in the UI layer.

---

## Threat 4: Secrets Exposure

**Scenario:** AWS credentials, tokens, or other sensitive config values are leaked via code, logs, environment variables, or the GitHub repository.

**Attack vectors:**
- Hardcoded secrets in Terraform files or Python source code committed to GitHub
- Lambda environment variables logged or exposed via a misconfigured endpoint
- Long-lived AWS access keys stored in GitHub Actions secrets
- Over-privileged IAM role assumed by GitHub Actions

**Controls in place:**

| Control | Where | Effectiveness |
|---|---|---|
| No static AWS credentials anywhere | Architecture — GitHub Actions uses OIDC; no IAM access keys exist | Eliminates the most common credential leak vector |
| GitHub Actions OIDC role scoped to this repo + branch | `infra/github-oidc/` trust policy | A compromised GitHub token from another repo cannot assume this role |
| Lambda env vars contain only non-secret config | Audited 2026-04-10 — table names, User Pool IDs only | No credentials, tokens, or Cognito client secrets are in env vars |
| SSM Parameter Store Standard designated for all future secrets | Architecture decision | When third-party API keys, SMTP credentials, or connection strings are needed, they go to SSM; Lambda gets `ssm:GetParameter` scoped to the specific path |
| Structured logs exclude PII and secrets | Log field schema: `level, message, requestId, userSub, route, statusCode, latencyMs, restaurantId` | No tokens, emails, or scores appear in CloudWatch logs |
| Admin UI tokens in `sessionStorage` (not `localStorage`) | `admin.js` | Tokens are cleared when the browser tab closes; not accessible to other tabs or cross-origin JS |
| `.gitignore` excludes `*.tfvars` local overrides, `.env` files | Repo config | Prevents accidental commit of local credential overrides |
| IaC security scanning (Checkov) required CI gate | `.github/workflows/terraform.yml` | Blocks PRs that introduce Checkov-detected misconfigurations |
| Python dependency scanning (`pip-audit`) in CI | Sprint 13 | Blocks PRs with known vulnerable Python packages |

**Residual risks:**
- Admin UI `config.json` (deployed to S3/CloudFront at `/admin/config.json`) contains the API endpoint URL, Cognito domain, and Cognito client ID. These are not secrets — they must be known by the browser to initiate the OAuth flow. They are equivalent to public OAuth metadata.
- Lambda environment variables are visible to anyone with `lambda:GetFunctionConfiguration`. Table names and User Pool IDs are not credentials; no current env vars are sensitive.
- SSM Parameter Store Standard tier does not support automatic rotation. If a secret requires rotation, Secrets Manager is the correct tool. No current secrets require rotation.

---

## Control Coverage Matrix

| Threat | Edge (WAF/CloudFront) | Auth (Cognito/JWT) | App Layer | Admin / Audit |
|---|---|---|---|---|
| Rating stuffing | Per-IP rate limit [prod]; CommonRuleSet [prod] | One rating/user/restaurant (sub from JWT) | Score + restaurant_id validation | `rating_events` audit log; audit log endpoint; spike alarm |
| Privilege escalation | WAF at CloudFront edge [prod] | JWT authorizer; per-env User Pools | Admin group check (server-side, every admin route); action allowlist; self-disable prevention | CloudWatch Lambda error alarms |
| Injection | CommonRuleSet + KnownBadInputs [prod] | — | Input validation; DynamoDB parameterized API; action allowlist | Structured logs; WAF sampled request logs |
| Secrets exposure | — | OIDC; no static keys | SSM for secrets; no PII in logs; sessionStorage for tokens | Checkov CI gate; pip-audit CI gate |

---

## Phase 3 Deliverables — Completion Status

| Deliverable | Status | Notes |
|---|---|---|
| Checkov IaC scanning in CI | ✅ Complete (Sprint 11) | Required status check on `main` |
| CloudWatch alarms: Lambda errors, API 5xx/latency/throttles | ✅ Complete (Sprint 12) | Dev + prod |
| Python lint + pip-audit dependency scanning | ✅ Complete (Sprint 13) | |
| WAF WebACL with managed rules + rate limit | ✅ Complete (Sprint 15) | Prod-only; now CLOUDFRONT scope |
| Threat model v1 | ✅ Complete (Sprint 16) | |
| SSM audit — no credentials in env vars | ✅ Complete (Sprint 19) | |
| Rating spike CloudWatch alarm | ✅ Complete (Sprint 19) | |
| Structured logging audit | ✅ Complete (Sprint 20) | All Lambdas use structured JSON |
| S3 + CloudFront static site | ✅ Complete (Sprint 21) | OAC; public access blocked |
| WAF re-scoped to CLOUDFRONT; associated with CloudFront | ✅ Complete (Sprint 22) | `web_acl_id` on distribution |
| Admin Cognito group + `/v1/admin/health` route guard | ✅ Complete (Sprint 23) | Server-side group check |
| Admin Lambda: list users + manage user | ✅ Complete (Sprint 24) | disable/enable/force_reset |
| Admin audit log endpoint | ✅ Complete (Sprint 25) | Query by restaurant_id |
| Admin UI (S3 + CloudFront) | ✅ Complete (Sprint 25) | Implicit flow; sessionStorage |
| Threat model v2 | ✅ Complete (Sprint 25) | This document |
| Per-user rate limiting (JWT sub) | ⏳ Deferred | Phase 4 — Lambda@Edge |
| New-account submission throttle | ⏳ Deferred | Phase 4 |
| DynamoDB KMS CMK encryption | ⏳ Deferred | Checkov skip documented |
| GuardDuty | ⏳ Deferred | Phase 4, prod only |

---

## Out of Scope

- **DDoS at scale:** WAF rate limits provide basic protection; AWS Shield Standard covers volumetric L3/L4 attacks automatically. Shield Advanced is not in scope.
- **GuardDuty:** Threat detection for anomalous API calls and compromised credentials. Planned for Phase 4 (prod only).
- **Account takeover on Cognito Hosted UI:** No CAPTCHA or MFA currently. Cognito provides basic brute-force throttling.
- **Supply chain attacks:** Python dependency scanning (`pip-audit`) runs in CI. Terraform provider pinning is in place.
- **KMS CMK for DynamoDB/CloudWatch:** Default AWS encryption at rest is in place. CMK adds cost and operational complexity without meaningful benefit for this workload at this scale.
