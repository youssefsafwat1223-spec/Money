# Mali Engineering Handbook

**Mali** (Arabic: قرش / Qirsh) is an Arabic-first, on-device expense tracker that automatically imports transactions from bank SMS messages. Package: `money_companion`. Bundle ID: `com.youssefsafwat.mali`.

This handbook is the complete engineering reference for the project. It is written so that any engineer — human or AI (Claude, Codex, Gemini, Cursor, etc.) — can pick up this repository cold and understand, maintain, test, extend, and safely release it without needing side-channel context.

## Who this is for

- A new engineer joining the project with zero prior context.
- An AI coding agent given a ticket against this repo.
- A release manager preparing a production deployment.
- An on-call engineer responding to a production incident at 3am.
- A QA engineer designing a regression suite for a new feature.

## How to use this handbook

Read in this order if you are onboarding from scratch:

1. **[00_SYSTEM_PROMPT.md](00_SYSTEM_PROMPT.md)** — the operating contract for any AI agent working in this repo.
2. **[01_GLOBAL_RULES.md](01_GLOBAL_RULES.md)** — non-negotiable engineering rules.
3. **[02_PROJECT_DISCOVERY.md](02_PROJECT_DISCOVERY.md)** — what Mali is, who it's for, the product shape.
4. **[03_ARCHITECTURE.md](03_ARCHITECTURE.md)** — system architecture, all moving parts.
5. **[04_DATABASE.md](04_DATABASE.md)** — Drift (on-device) and Supabase/Postgres (backend) schemas.
6. **[05_BACKEND.md](05_BACKEND.md)** — Supabase project: Edge Functions, RLS, RPCs, auth.
7. **[06_FLUTTER.md](06_FLUTTER.md)** — the Flutter app: layers, state management, navigation.
8. **[07_SECURITY.md](07_SECURITY.md)** — threat model, encryption, secrets, RLS posture.
9. **[08_FEATURES.md](08_FEATURES.md)** — every user-facing feature, in detail.
10. **[09_DATA_FLOW.md](09_DATA_FLOW.md)** — how data moves end-to-end for every major flow.

Reference on demand (not necessarily sequential):

11. **[10_TEST_STRATEGY.md](10_TEST_STRATEGY.md)** — the overall QA philosophy and test pyramid.
12. **[11_TEST_MATRIX.md](11_TEST_MATRIX.md)** — hundreds of concrete test scenarios, IDs, and expected results.
13. **[12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md)** — how to validate DB state directly (SQL playbooks).
14. **[13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md)** — the full notification pipeline, path by path.
15. **[14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md)** — the full SMS/Shortcut capture pipeline.
16. **[15_PERFORMANCE.md](15_PERFORMANCE.md)** — performance budgets, profiling, known hot paths.
17. **[16_STRESS_TESTING.md](16_STRESS_TESTING.md)** — load/stress/chaos testing playbooks.
18. **[17_BUG_WORKFLOW.md](17_BUG_WORKFLOW.md)** — how a bug is triaged, reproduced, fixed, verified.
19. **[18_REGRESSION.md](18_REGRESSION.md)** — the regression suite and when it must run.
20. **[19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md)** — how to cut and ship a release.
21. **[20_FINAL_REPORT_TEMPLATE.md](20_FINAL_REPORT_TEMPLATE.md)** — the standard report template for any significant change.
22. **[21_CHECKLISTS.md](21_CHECKLISTS.md)** — every checklist (code review, DB, backend, Flutter, release, production).
23. **[22_CODING_STANDARDS.md](22_CODING_STANDARDS.md)** — style, naming, folder conventions.
24. **[23_GIT_WORKFLOW.md](23_GIT_WORKFLOW.md)** — branching, commits, PRs.
25. **[24_MONITORING.md](24_MONITORING.md)** — logging, metrics, alerting, dashboards.
26. **[25_DISASTER_RECOVERY.md](25_DISASTER_RECOVERY.md)** — what to do when things break badly.
27. **[26_BACKUP_STRATEGY.md](26_BACKUP_STRATEGY.md)** — backup/restore for Drift and Supabase.
28. **[27_DEPLOYMENT_GUIDE.md](27_DEPLOYMENT_GUIDE.md)** — how to deploy every layer of the system.
29. **[28_PRODUCTION_RUNBOOK.md](28_PRODUCTION_RUNBOOK.md)** — day-2 operations runbook.
30. **[29_AI_EXECUTION_GUIDE.md](29_AI_EXECUTION_GUIDE.md)** — how an AI agent should execute tasks in this repo.
31. **[30_ROADMAP.md](30_ROADMAP.md)** — where the project is going next.
32. **[31_FULL_MANUAL_QA.md](31_FULL_MANUAL_QA.md)** — the complete, sequential, start-to-finish manual release-validation playbook, from a brand-new install through final sign-off.

## Document conventions

- 🟢 = safe / expected / healthy state
- 🟡 = caution / requires judgment
- 🔴 = stop / do not proceed without explicit approval
- All SQL is PostgreSQL (Supabase) unless explicitly marked "Drift/SQLite".
- All Dart code assumes the Flutter/Riverpod stack described in [06_FLUTTER.md](06_FLUTTER.md).
- Every test scenario in [11_TEST_MATRIX.md](11_TEST_MATRIX.md) has a stable `ID` that other documents may reference (e.g. `AUTH-014`, `CAP-102`).

## Source of truth hierarchy

When documentation and code disagree, the code wins. This handbook is a map, not the territory. Specifically:

1. `app/lib/data/db/app_database.dart` is authoritative for the Drift schema.
2. `supabase/migrations/*.sql` (in order) is authoritative for the Postgres schema.
3. `app/CLAUDE.md` and the root `CLAUDE.md` are authoritative for behavioral/process rules and override this handbook if they ever conflict.
4. This handbook is authoritative for *process, strategy, and cross-cutting understanding* that doesn't live naturally in code.

## Maintenance

This handbook must be updated in the same PR as any change that:
- Adds/removes a database table, column, RPC, or Edge Function.
- Adds/removes a feature flag.
- Changes the notification or capture pipeline.
- Changes the release or deployment process.

Stale documentation is worse than no documentation — it actively misleads. Treat handbook updates as part of the definition of done.
