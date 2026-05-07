# Runbook: Environment Teardown

## Scenarios

**Scenario A — Dev teardown between sessions**
Tear down dev to stop idle charges on any per-resource services. Prod stays live.
WAF and CloudFront are prod-only, so dev teardown saves almost nothing currently — but the pattern is correct for when dev gets more expensive services.

**Scenario B — Full project shutdown**
Destroy all environments: prod → dev → GitHub OIDC role.
Use when the project is being retired or archived.

---

## What Is NOT Destroyed (preserve in all scenarios)

| Resource | Why |
|---|---|
| `bbq-tfstate-justin` S3 bucket | Holds Terraform state for all envs; destroy last or never |
| `bbq-tfstate-justin` DynamoDB lock table | Required to re-initialize any env |
| GitHub OIDC role (`infra/github-oidc/`) | Destroys CI — only do this in Scenario B, last |

---

## Pre-Teardown Checklist

- [ ] Export any data you want to keep (DynamoDB → S3 backup or JSON export)
- [ ] Note the Cognito User Pool IDs if you need to re-import test users later
- [ ] Confirm no CI job is currently running (`gh run list --limit 5`)
- [ ] If doing prod teardown: inform any active users (N/A for portfolio project)

---

## Step 1 — Empty S3 Buckets (required before `terraform destroy`)

Terraform will fail on non-empty S3 buckets. The static site bucket has versioning
enabled, so you must delete all versions and delete markers, not just objects.

**Find the bucket name:**
```
cd infra/envs/<env>
~/bin/terraform output static_site_bucket
```

**Delete all versions and delete markers (replace `<bucket>` with actual name):**
```
aws s3api delete-objects --bucket <bucket> --delete "$(aws s3api list-object-versions --bucket <bucket> --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)"
```

**Delete delete markers (run if the above returns an error about delete markers):**
```
aws s3api delete-objects --bucket <bucket> --delete "$(aws s3api list-object-versions --bucket <bucket> --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)"
```

**Verify bucket is empty:**
```
aws s3 ls s3://<bucket> --recursive
```

---

## Step 2 — Terraform Destroy

> **Note:** `terraform apply` is CI-only per ADR 0002, but `terraform destroy` has
> no CI workflow. Local destroy is the intentional exception — treat it with the same
> care as a prod apply: review the plan, confirm resource list before approving.

**Always destroy prod before dev (prod depends on no dev resources, but this order
avoids any shared-state confusion). Destroy OIDC role last.**

### Dev environment

```
cd infra/envs/dev
~/bin/terraform init
~/bin/terraform destroy
```

Review the plan output. Confirm the resource count looks right before typing `yes`.

### Prod environment (Scenario B only)

```
cd infra/envs/prod
~/bin/terraform init
~/bin/terraform destroy
```

CloudFront distributions take 10–15 minutes to fully disable and delete.
Terraform will wait — do not interrupt the process.

### GitHub OIDC role (Scenario B only — destroys CI)

```
cd infra/github-oidc
~/bin/terraform init
~/bin/terraform destroy
```

After this, all GitHub Actions jobs that assume the OIDC role will fail.

---

## Step 3 — Clean Up CloudWatch Log Groups (optional)

Log groups are Terraform-managed and will be destroyed with `terraform destroy`.
If you interrupted a destroy or log groups were created outside Terraform:

```
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/bbq- --query 'logGroups[].logGroupName' --output text
aws logs describe-log-groups --log-group-name-prefix aws-waf-logs-bbq --query 'logGroups[].logGroupName' --output text
```

Delete any orphaned groups:
```
aws logs delete-log-group --log-group-name <log-group-name>
```

---

## Step 4 — Destroy State Bucket (Scenario B final step only)

Only do this after all environments are destroyed and you are certain you will
not need to re-initialize any of them.

```
aws s3 rm s3://bbq-tfstate-justin --recursive
aws s3api delete-bucket --bucket bbq-tfstate-justin
aws dynamodb delete-table --table-name bbq-tfstate-lock
```

---

## Step 5 — Cost Verification

WAF stops billing immediately on WebACL deletion ($5/month saved).
CloudWatch logs stop ingestion billing when log groups are deleted.
DynamoDB and Lambda have no idle cost — no action needed.

**Verify in Cost Explorer 24–48 hours after teardown:**
1. AWS Console → Billing → Cost Explorer
2. Group by Service, look for WAF, CloudWatch, Lambda lines dropping to $0

---

## Bringing the Environment Back Up

Since CI-only applies are enforced, re-deploy by pushing a commit to main:

```
git commit --allow-empty -m "chore: trigger redeploy after teardown"
git push origin main
```

The `apply-dev` and `apply-prod` CI jobs will re-create all resources from state.
State bucket must exist and be accessible — if it was destroyed (Scenario B),
you must re-create it manually and re-initialize each env before CI can run.
