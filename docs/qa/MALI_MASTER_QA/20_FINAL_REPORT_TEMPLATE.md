# 20 — Final Report Template

Related: [00_SYSTEM_PROMPT.md](00_SYSTEM_PROMPT.md) §6, [17_BUG_WORKFLOW.md](17_BUG_WORKFLOW.md), [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md).

Every significant task (a bug fix touching more than a trivial code path, a schema change, a deployment, a QA cycle) ends with a report in this shape — not an open-ended narrative. This keeps reports comparable across tasks and ensures nothing required gets silently skipped.

## Template

```markdown
# <Task name> — Final Report

## 1. Summary
One or two sentences: what was done and why.

## 2. Findings / changes made
Enumerated list, each with: what, where (file/table/function), and why.

## 3. Files changed
List of files touched, grouped by layer (Flutter / Edge Functions / migrations / tests / docs).

## 4. Behavior changes
For each user- or system-visible behavior change: before → after.

## 5. Tests added/updated
List of test files and specific test names, mapped to what each one guards against.

## 6. Gate results
Exact output/pass-fail for every applicable gate from 10_TEST_STRATEGY.md §3:
- flutter analyze: ...
- flutter test: ...
- xcodebuild (Runner / affected extension schemes): ...
- deno check / deno test: ...
- git diff --check: ...
- Migration history sync check: ...
- Any live-database verification performed: ...

## 7. Global state verification
- Feature flags: list every flag touched and its exact before/after global state (must be OFF/0% unless an explicit cutover was authorized in this task).
- Any real user data touched: state explicitly "none" if true — do not leave this implicit.

## 8. Remaining manual steps
Explicit list of anything requiring a human/device action, each labeled MANUAL QA REQUIRED where applicable, with a pointer to the exact procedure (e.g., 13_NOTIFICATION_PIPELINE.md §7 Step N).

## 9. Commit-safety verdict
Yes/No + one-line justification. If No, state exactly what's blocking it.

## 10. Deploy-safety verdict
Yes/No + one-line justification, separately for app and backend if they differ.

## 11. Rollback plan (if applicable)
How to undo this change if it turns out to be wrong, and how fast.

## 12. Open questions / explicit assumptions
Anything the report's author was not fully certain about, stated plainly rather than smoothed over.
```

## Why this exists

Prior to standardizing this format, task closures tended to drift toward either (a) an exhaustive but hard-to-scan narrative, or (b) a report that implicitly assumed gates passed without stating results explicitly. Both failure modes are addressed by requiring §6 (exact gate results, not "tests pass") and §9/§10 (explicit yes/no verdicts, not implied by the rest of the report reading positively).

## Worked example (abbreviated) — from the notification/capture pipeline hardening task

```markdown
# Notification & Capture Pipeline Hardening — Final Report

## 1. Summary
Fixed 16 findings from a prior read-only audit of the SMS capture and notification
pipeline, spanning a critical dedup-marker retention bug down to minor atomicity
and UX-copy issues. No architecture changes beyond the audited findings.

## 2. Findings / changes made
[16 numbered items, P0 through P3 — see 18_REGRESSION.md REG-005 through REG-016
plus REG-001 through REG-004 discovered in an earlier related pass]

## 6. Gate results
- flutter analyze: 0 issues
- flutter test: 524/524 passed
- xcodebuild Runner (iphonesimulator, unsigned): BUILD SUCCEEDED
- xcodebuild BankMessageShortcuts (iphonesimulator, unsigned): BUILD SUCCEEDED
- deno check (process-ios-sms, _shared/apns.ts, _shared/ledger.ts, sync-captures): clean
- deno test (_shared/capture_fingerprint_test.ts): 6/6 passed
- git diff --check: clean

## 7. Global state verification
- All 9 Supabase-primary/capture flags confirmed OFF (is_active=false, rollout_percent=0)
  both before and after this task.
- No real user data touched — all live verification used a throwaway QA install ID
  (qa-hardening-smoke-2026-07-13), cleaned up after verification (rows deleted,
  final total capture-row count confirmed unchanged from before the smoke test).

## 9. Commit-safety verdict
Yes — all gates green, changes strictly scoped to the audited findings.

## 10. Deploy-safety verdict
Yes for the reviewed diff; migration 0033 and the process-ios-sms redeploy require
separate explicit approval before touching the live project (data-safety review
performed but not self-authorized).
```

This worked example is deliberately abbreviated for illustration — a real report fills every section completely, per §"Template" above.
