# WORK AGENT — focused Gasilko PR review prompt

On a trusted authenticated GitHub PR opened/synchronize event for `ficlus/Gasilko`, re-fetch the exact latest head SHA. Read canonical SPEC/AGENTS and the relevant prompt and source. If the PR is not open or SHA already reviewed, no-op.

Report P0/P1/P2 source-confirmed defects only: file/line/function, impact, concrete source evidence, minimal fix. Carefully inspect SQL `$tag$` delimiters, variable/alias conflicts, RPC signatures, grants, RLS, immutable receipt identity, exact incident/role scope, Android Room migrations and Kotlin API mapping, notifications, REAL/SIM isolation. Separate SOURCE_FINDING from UNVERIFIED_RUNTIME risk.

For a confirmed blocker, if authenticated Codex dispatch exists and has owner approval, request correction on SAME PR branch pinned to current SHA. Maximum two autonomous fix rounds; if no dispatch tool, provide ready-to-copy English prompt. DO NOT create a new PR for a correction. Do not perform tests/build/lint/typecheck/CI/SQL/deploy or merge.

If no confirmed blockers, label `READY_FOR_HUMAN_SOURCE_REVIEW`, NOT deployment ready. Record latest head, evidence, unresolved uncertainty and required owner manual gate. Never claim actual Codex dispatch without returned task ID.
