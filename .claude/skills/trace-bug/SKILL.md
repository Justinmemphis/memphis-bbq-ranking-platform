---
name: trace-bug
description: Investigate a bug or CI failure, identify root cause, and propose the minimal fix
context: fork
agent: Explore
---

Investigate the bug or failure described in $ARGUMENTS.

Process:
1. **Reproduce** — find the error message, stack trace, or failing test
2. **Locate** — find the relevant files and lines using search tools
3. **Hypothesize** — list 2–3 candidate root causes ordered by likelihood
4. **Diagnose** — rule out candidates by reading the code; identify the real cause
5. **Propose** — describe the minimal fix; note any risks or side effects
6. **Validate** — describe how to confirm the fix worked

Include specific file:line references. Do not modify files — this is a diagnosis skill only.
