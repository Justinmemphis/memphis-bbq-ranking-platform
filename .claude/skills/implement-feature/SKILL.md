---
name: implement-feature
description: Implement a scoped feature end-to-end: plan, implement, test, summarize risks
---

Implement the feature described in $ARGUMENTS.

Process:
1. **Restate** the requirement in one paragraph
2. **Explore** — find relevant files and existing patterns before writing anything
3. **Plan** — propose the smallest viable implementation; pause if the approach is unclear
4. **Implement** — make the changes following existing patterns
5. **Test** — add or update tests for any behavior change
6. **Validate** — run `terraform fmt && terraform validate` for infra changes; `ruff check` for Python
7. **Summarize**:
   - Files changed
   - Security or cost implications
   - Follow-up work needed

Do not run `terraform apply` or `git push`.
Flag anything touching IAM, networking, auth, data deletion, or billing before proceeding.
