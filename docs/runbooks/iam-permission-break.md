# Runbook: Lambda IAM Permission Break

## Scenario

A Lambda function loses a required IAM permission — either by accidental manual removal,
a bad Terraform apply, or a policy drift incident. The function begins returning 5xx errors.

## Symptoms

- `POST /v1/ratings` (or other write endpoints) returns `500`
- CloudWatch alarm `bbq-prod-submit-rating-spike` enters ALARM state
- Lambda Errors row on the ops dashboard shows a spike
- Lambda logs contain `AccessDeniedException` from DynamoDB

## Detection

1. Check the ops dashboard: Lambda Errors row shows spike at time of incident
2. Check the alarm: `bbq-prod-submit-rating-spike` in ALARM state
3. Confirm in Lambda logs (CloudWatch Log Insights):

```
fields @timestamp, @message
| filter @message like /AccessDeniedException/
| sort @timestamp desc
| limit 20
```

4. Confirm IAM state — list inline policies on the affected role:

```
aws iam list-role-policies --role-name bbq-prod-submit-rating-exec
```

If `bbq-prod-submit-rating-additional` is missing, the policy was removed.

## Remediation

### Option A — Re-apply via CI (preferred, keeps Terraform state clean)

Push a no-op commit to main or re-run the `apply-prod` workflow. Terraform will detect
the drift and re-attach the missing policy.

### Option B — Emergency manual restore

Use this only if CI is unavailable and the outage is active.

1. Get the correct policy document from Terraform source:

```
cat infra/envs/prod/main.tf
```

Find the `additional_policy_json` block for `lambda_submit_rating` and reconstruct the
policy document, or retrieve it from a recent backup:

```
aws iam get-role-policy --role-name bbq-prod-submit-rating-exec --policy-name bbq-prod-submit-rating-additional > /tmp/policy_doc.json
```

2. Re-attach:

```
aws iam put-role-policy --role-name bbq-prod-submit-rating-exec --policy-name bbq-prod-submit-rating-additional --policy-document file:///tmp/policy_doc.json
```

3. Verify — IAM changes take effect immediately, no Lambda redeploy needed:

```
curl -s -o /dev/null -w "%{http_code}" -X POST https://6iq57bhwj5.execute-api.us-east-1.amazonaws.com/v1/ratings \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"restaurant_id":"cozy-corner","score":4}'
```

Expect `200`.

4. After recovery, trigger a CI apply to reconcile Terraform state with actual AWS state.

## Chaos Drill Record

**Date:** 2026-05-01
**Performed by:** Justin

**Steps taken:**
1. Deleted `bbq-prod-submit-rating-additional` inline policy from `bbq-prod-submit-rating-exec`
2. Confirmed `POST /v1/ratings` returned `500`
3. Restored policy via `aws iam put-role-policy` with extracted policy doc
4. Confirmed `POST /v1/ratings` returned `200`

**Time to detect:** Immediate (manual trigger, not from alarm)
**Time to remediate:** ~3 minutes

**Finding:** IAM changes propagate instantly — no Lambda cold start or redeploy needed for
permission restores. The `bbq-prod-submit-rating-spike` alarm would fire within 1–2 evaluation
periods (1–2 minutes) under real traffic.
