---
name: review-security
description: Security-focused review of changes touching IAM, auth, API inputs, or data access
context: fork
agent: reviewer
---

Perform a security-focused review of $ARGUMENTS (or recent changes if not specified).

Focus areas:
1. **IAM** — are permissions least-privilege? Is `Resource: "*"` justified and documented?
2. **Auth** — JWT claims read correctly? Cognito `sub` used as user key everywhere?
3. **Input validation** — are API inputs validated at the boundary?
4. **Data access** — DynamoDB PK/SK patterns correct? No table scans where point reads are possible?
5. **Secrets** — no credentials in code, env vars in Lambda are not secrets
6. **Logging** — no PII logged; only allowed fields present
7. **Terraform** — no hardcoded account IDs, no open security groups, encryption enabled on buckets/tables

Return findings ordered by severity (Critical / Warning / Suggestion) with file:line references and concrete fixes.
