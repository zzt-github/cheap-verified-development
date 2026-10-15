---
name: cheap-verified-development
description: Implement or repair software in an existing repository using a low-cost coding worker, deterministic checks, and a bounded independent review. Use for coding, feature implementation, bug fixes, refactoring, and frontend, backend, API, or test work.
---

# Cheap, verified development

Use this workflow for repository changes when subagents are available. The root agent owns the request, acceptance criteria, safety boundaries, and final result; delegate the bulk of implementation and review.

1. Turn the request into concrete acceptance criteria and identify any irreversible or production actions. Preserve existing user changes.
2. Give ordinary implementation to `worker_luna` with a focused task and relevant paths. Keep the worker's context bounded; use `fork_turns: none` where supported and include all necessary requirements in the task itself.
3. Inspect the diff and identify the repository's existing deterministic checks. Run relevant tests, lint, typecheck, and build commands that are defined by the project; do not invent scripts or report unrun checks as passing.
4. If checks fail, return the exact output and affected paths to the same worker for repair, then rerun the relevant checks. Do not ask a model reviewer to diagnose ordinary failing tests.
5. After deterministic checks pass, give `reviewer_astra` a compact verification package: task, acceptance criteria, changed-file diff, changed files, and check results. Ask for an independent, read-only review.
6. If review returns actionable findings, send only those findings plus relevant evidence to the same worker. Rerun deterministic checks after each repair, then review again. Keep ordinary repair attempts to about two rounds.
7. Escalate only the specific unresolved dispute to `reviewer_astra_high` when the low reviewer is uncertain, a high-risk category applies, the low reviewer finds substantive issues twice, or two worker repair rounds fail. High-risk categories include safety, permissions, data loss, database migration, concurrency, complex architecture, and irreversible operations.
8. Never treat a reviewer PASS as a substitute for tests. Never perform destructive, production, cloud, payment, force-push, or other irreversible actions without the required user authorization.

If a named agent is unavailable, use the matching model and role only when the runtime supports it; be explicit about any routing limitation. If deterministic checks cannot run, report that limitation rather than claiming verification.
