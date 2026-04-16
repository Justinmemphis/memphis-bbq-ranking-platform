---
name: ship-pr
description: Prepare a branch for PR — review diff, stage files, commit with a good message, draft PR description
allowed-tools: Bash(git status), Bash(git diff *), Bash(git add *), Bash(git commit *), Bash(gh pr create *)
---

Prepare the current branch for a pull request.

Steps:
1. Run `git status` and `git diff` — review all changes
2. Confirm nothing unexpected is staged (no .env, no secrets, no large binaries)
3. Group related changes into logical commits if needed
4. Write a commit message: short imperative subject line, body explaining why
5. Stage and commit
6. Draft a PR description:
   - **Summary**: 1–3 bullet points of what changed and why
   - **Test plan**: what to verify before merging
   - **Checklist**: tf fmt/validate, lint, tests, IaC scan
7. Present the `gh pr create` command for review — do NOT run it without user confirmation

Do not run `git push`. Do not merge or close PRs.
Note: For any infra change, remind the user to run `terraform fmt`, `terraform validate`, `tflint`, and review the plan output before approving.
