# Runbook: Incident Response

## Alarm Inventory

| Alarm | Threshold | Fires when |
|---|---|---|
| `bbq-prod-{fn}-errors` | ≥ 1 error / 5 min | Any Lambda unhandled exception or timeout |
| `bbq-prod-apigw-5xx` | ≥ 5 errors / 5 min | Raw 5xx count — catches bursts at low traffic |
| `bbq-prod-apigw-error-rate` | ≥ 1% / 5 min | SLO breach — error rate at any traffic level |
| `bbq-prod-apigw-latency-p99` | ≥ 500 ms / 10 min sustained | SLO breach — p99 latency (2 evaluation periods) |
| `bbq-prod-submit-rating-spike` | ≥ 200 invocations / 5 min | Potential bot or rating stuffing |
| `bbq-prod-apigw-throttles` | ≥ 10 4xx errors / 5 min | WAF blocks, API GW throttles, or 429s |

All alarms publish to SNS topic `bbq-prod-alarms`. Email arrives from AWS when state
transitions to ALARM or back to OK.

**Ops dashboard:** AWS Console → CloudWatch → Dashboards → `bbq-prod-ops`

---

## First Response (any alarm)

1. Open the ops dashboard — check all four rows simultaneously:
   - Row 1 (API Health): which metric spiked and when?
   - Row 3 (Lambda Errors): which function(s) are erroring?
   - Row 4 (Alarm Status): how many alarms are in ALARM state?

2. Check recent deploys — if an alarm fired within 10 minutes of a merge to main,
   suspect the deploy first:
   ```
   gh run list --limit 5
   ```

3. Determine blast radius: is one endpoint affected or all of them?
   - One Lambda alarm + matching 5xx alarm → likely a code or IAM issue on that function
   - All Lambda alarms + 5xx surge → DynamoDB, cold start wave, or bad deploy
   - Latency alarm only, no errors → DynamoDB throttle or Lambda duration regression

---

## Scenario 1 — Lambda Error Spike

**Alarm:** `bbq-prod-{fn}-errors`

**Most common causes:** unhandled exception in handler code, IAM permission removed
(see `docs/runbooks/iam-permission-break.md`), DynamoDB table missing or throttled,
malformed event shape from API Gateway.

### Investigate

Identify the error in Log Insights (replace `{fn}` with the function name, e.g. `bbq-prod-submit-rating`):

```
fields @timestamp, @message, @requestId
| filter @message like /ERROR/ or @message like /Exception/ or @message like /AccessDeniedException/
| sort @timestamp desc
| limit 50
```

Run against log group: `/aws/lambda/{fn}`

**If `AccessDeniedException`:** follow `docs/runbooks/iam-permission-break.md`.

**If a Python exception:** look for the traceback — the structured log will have
`"level": "ERROR"` and `"message"` with the exception text.

```
fields @timestamp, message, requestId, route, statusCode
| filter level = "ERROR"
| sort @timestamp desc
| limit 50
```

### Remediate

| Root cause | Action |
|---|---|
| Code bug introduced in recent deploy | Revert: push a revert commit to main; CI will redeploy |
| IAM permission removed | Follow iam-permission-break.md |
| DynamoDB throttle | Check DynamoDB console → `bbq-prod-ratings` → Metrics → Throttled requests; switch to on-demand if provisioned |
| Malformed event | Check API Gateway → Logs to confirm event shape is as expected |

---

## Scenario 2 — 5xx Surge

**Alarms:** `bbq-prod-apigw-5xx` and/or `bbq-prod-apigw-error-rate`

A 5xx surge almost always traces back to a Lambda error — the API Gateway itself rarely
fails. Use this runbook to localize which Lambda is responsible, then follow Scenario 1.

### Investigate

**Step 1 — Identify the failing route.** API Gateway access logs contain the route and status:

```
fields @timestamp, requestId, routeKey, status, integrationErrorMessage
| filter status >= 500
| stats count(*) by routeKey
| sort count desc
```

Log group: the API Gateway access log group (named by the `api_http` module, e.g.
`/aws/apigateway/bbq-prod`).

**Step 2 — Correlate to Lambda error.** Take the `requestId` from a failing request and
search the corresponding Lambda log group:

```
fields @timestamp, @message
| filter @requestId = "<requestId>"
```

**Step 3 — Check for DynamoDB errors across all functions:**

```
fields @timestamp, @message
| filter @message like /ProvisionedThroughputExceededException/ or @message like /ResourceNotFoundException/
| sort @timestamp desc
| limit 20
```

### Remediate

Same options as Scenario 1. If the surge is on a single route, disable that route at the
API Gateway level as a stop-gap (remove its integration temporarily) while the root cause
is fixed. For a full-stack outage (all routes returning 5xx), check DynamoDB table status
first — a table deletion or throttle would affect every write and read path simultaneously.

---

## Scenario 3 — p99 Latency SLO Breach

**Alarm:** `bbq-prod-apigw-latency-p99` (fires only after 10 min sustained — not a
cold-start false alarm)

A latency alarm without accompanying error alarms usually means requests are succeeding
but slowly. Common causes: DynamoDB read/write latency regression, Lambda cold start
wave (new deploy, low traffic period), Lambda memory too low causing CPU-bound slowness.

### Investigate

**Step 1 — Check Lambda duration:**

```
fields @timestamp, @duration, @billedDuration, @memorySize, @maxMemoryUsed
| sort @duration desc
| limit 50
```

Run across each Lambda log group. Compare `@duration` against historical baseline
(load test median GET = 44ms, POST = 341ms). A sudden jump in duration points to
the function.

**Step 2 — Check DynamoDB latency:**

AWS Console → DynamoDB → `bbq-prod-ratings` (or `bbq-prod-restaurants`) → Metrics →
`SuccessfulRequestLatency`. If DynamoDB latency is elevated, the issue is the table,
not Lambda code.

**Step 3 — Check for cold start wave:**

```
fields @timestamp, @initDuration, @duration
| filter @initDuration > 0
| sort @timestamp desc
| limit 20
```

A cluster of `@initDuration` entries after a deploy or a low-traffic period is a cold
start wave, not a regression. No action needed — latency self-recovers as functions warm.

### Remediate

| Root cause | Action |
|---|---|
| Cold start wave | Wait — latency recovers as Lambdas warm (typically < 5 min) |
| DynamoDB throttle | Check provisioned vs actual; DynamoDB PAY_PER_REQUEST shouldn't throttle unless table is in CREATING/RESTORING state |
| Lambda memory too low | Increase `memory_size` in the Lambda module variable for the slow function; deploy via CI |
| Code regression (e.g. N+1 DynamoDB calls) | Identify the function from duration data; revert or fix and redeploy |

---

## Scenario 4 — Rating Submission Spike (Potential Abuse)

**Alarm:** `bbq-prod-submit-rating-spike` (fires at ≥ 200 invocations / 5 min = 40/min)

This alarm fires on volume, not errors — a bot submitting valid ratings won't appear
in the error alarms. Investigate before assuming it's malicious (could be a load test,
a burst of legitimate traffic, or a client bug retrying aggressively).

### Investigate

**Step 1 — Check WAF sampled requests** (catches per-IP patterns):

AWS Console → WAF → Web ACLs → `bbq-prod-waf` → Sampled requests → filter by rule
`RateLimit`. If one IP is sending the bulk of requests, WAF should have already blocked
them (rate limit rule is in prod). If traffic is spread across many IPs, suspect
distributed abuse.

**Step 2 — Query the rating_events audit log for submission patterns:**

```
fields @timestamp, userSub, restaurantId
| filter route = "POST /v1/ratings"
| stats count(*) by userSub
| sort count desc
| limit 20
```

A single `userSub` submitting hundreds of ratings is account abuse. Many `userSub`
values with the same pattern suggests bot accounts created to evade per-account limits.

**Step 3 — Check leaderboard integrity:**

Query `bbq-prod-leaderboard-snapshot` in DynamoDB console. If a single restaurant
has a suspiciously high `rating_count` relative to others, ratings may have landed
before WAF blocked the source.

### Remediate

| Situation | Action |
|---|---|
| Single IP — WAF already blocked | No action; monitor for recurrence |
| Single IP — WAF not blocking | Add IP to WAF IP block list manually in console; file issue to automate |
| Single `userSub` account | Disable the Cognito user via admin UI or: `aws cognito-idp admin-disable-user --user-pool-id us-east-1_w9fKSXWtD --username <sub>` |
| Distributed abuse (many IPs/accounts) | Lower `rating_spike_threshold` in prod tfvars; consider enabling Lambda-level per-user rate limiting (deferred Phase 4 item) |
| Leaderboard skewed | Recompute leaderboard: invoke `bbq-prod-get-leaderboard` with a forced recompute, or manually correct affected restaurant's `rating_count` and `bayesian_score` in DynamoDB |

---

## Scenario 5 — Throttles / 4xx Spike

**Alarm:** `bbq-prod-apigw-throttles` (fires at ≥ 10 4xx errors / 5 min)

4xx spikes can be WAF blocks (429), API Gateway account-level burst limit hits (429),
client bugs sending malformed requests (400), or auth failures (401/403).

### Investigate

```
fields @timestamp, requestId, routeKey, status
| filter status >= 400 and status < 500
| stats count(*) by status, routeKey
| sort count desc
```

- **429s on many routes** → account-level burst limit or WAF rate rule firing
- **429s on one route** → route-level throttle configured in API Gateway
- **401s** → expired or missing JWT tokens (client bug or auth flow broken)
- **403s on `/v1/admin/`** → non-admin user hitting admin routes (expected, not a problem)
- **400s** → malformed request body; check client or Lambda input validation logs

---

## Post-Incident

After any ALARM → OK transition:

1. Confirm the ops dashboard shows all metrics back within normal range
2. Note the detection time (alarm fire) and remediation time (ALARM → OK)
3. If the incident was non-trivial, add a brief note to `docs/runbooks/` or as a
   comment on the relevant GitHub issue
4. If a configuration change (threshold, IAM policy, memory size) was made as
   emergency manual fix, open a PR to codify it in Terraform before the next session
