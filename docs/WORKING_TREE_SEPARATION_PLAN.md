# Mali — Working-Tree Separation Plan

Built by cross-referencing every Codex batch's own "files touched" report against the full working-
tree diff, corrected against direct diff reads where ambiguous. 188 changed/new paths total. Nothing
in this repo has been committed — this plan exists to make the eventual commit sequence deliberate
rather than a single blind commit of everything at once.

## 1. Pre-existing / unrelated to this remediation effort (do not bundle into any batch commit)

**~73 files** under `app/lib/` and `app/test/` — repositories, domain entities/usecases, and screen
widgets spanning accounts, budgets, cards, onboarding widgets, plans, subscriptions, capture services,
etc. These were already modified in the working tree **before** the adversarial-QA remediation arc
began (visible in this session's very first `git status`, before any batch was dispatched) and were
never mentioned in any Batch 1-4 delegation brief or Codex report. They belong to the separate,
ongoing "Supabase-primary migration" effort (Phases 1-8) that has been running in parallel across this
whole multi-day session. Full list available on request; representative examples:
`app/lib/data/repositories/supabase_account_repository.dart`,
`app/lib/features/budgets/budget_form_screen.dart`, `app/lib/features/cards/cards_carousel.dart`,
`app/lib/data/repositories/supabase_goal_repository.dart`, most of `app/lib/features/onboarding/widgets/`.

**3 files/directories of unclear origin, not referenced by anything in this remediation:**
- `MALI_MASTER_QA/` — the 31-file engineering handbook produced earlier this session, unrelated to
  the adversarial-QA batches.
- `generate_pdf.js`, `script.html` — no git history, no reference to any file in this repo found by
  grep; origin unclear. Recommend the user decide separately whether to keep, relocate, or delete
  these rather than folding them into any remediation commit.

**Action:** leave entirely alone. These are the user's/another workstream's responsibility, not this
task's.

## 2. Pre-adversarial-QA fixes (mid-session, before Batch 1 was dispatched)

- **Notification wording + APNs collapse-id fix:** `app/ios/BankMessageShortcuts/verify_notification_strings.sh`,
  `supabase/functions/_shared/apns.ts`, `apns_collapse_id.ts` (new), `apns_collapse_id_test.ts` (new),
  `apns_test.ts` (new).
- **Critical DB trigger fix:** `supabase/migrations/0034_fix_financial_child_ownership_trigger.sql` +
  rollback — already live, already verified this session.
- **Metrics-client launch-hang fix:** `app/lib/core/backend/metrics_client.dart`,
  `app/test/core/backend/metrics_client_test.dart` (new).
- **Auth/session architecture fix:** `app/lib/core/router/app_router.dart`, `app/lib/app.dart`,
  `app/lib/main.dart`, `app/test/core/session/app_session_test.dart`,
  `app/lib/features/dashboard/dashboard_screen.dart` (error-state branch for `AuthRepoException`).
- **Documentation produced this session (non-functional, safe):**
  `docs/ADVERSARIAL_QA_REMEDIATION_PLAN.md`, `docs/ADVERSARIAL_QA_REMEDIATION_PROGRESS.md`,
  `docs/USER_DELETION_DECISION_BRIEF.md`, `docs/MANUAL_IPHONE_QA_CHECKLIST.md`,
  `docs/WORKING_TREE_SEPARATION_PLAN.md` (this file).

**Action:** each of the three code fixes above is its own clean, independent, already-tested unit —
suitable as 3 separate commits distinct from the Batch 1-4 commits. The docs can land in one commit
together, or alongside whichever code commit they most directly document.

## 3. Batch 1 (findings #1-8) — admin auth, fingerprint race, device ownership, SMS durability, onboarding, accounts, bill UX

- **Admin:** all of `admin/middleware.ts`, `admin/lib/auth-guard.ts` (new), `admin/app/(admin)/layout.tsx`,
  every `admin/app/(admin)/**/page.tsx`, `admin/app/(auth)/login/page.tsx`,
  `admin/app/api/announcements/route.ts`, `admin/app/api/campaigns/route.ts`,
  `admin/app/api/admin-data/` (new), `admin/app/api/admin-session/` (new),
  `admin/app/not-authorized/` (new), `admin/tests/` (new), `admin/package.json`.
- **Capture backend:** `supabase/functions/process-ios-sms/index.ts`\*, `supabase/functions/sync-captures/index.ts`\*,
  `supabase/functions/unlink-capture-device/` (new), `supabase/functions/parser-test/index.ts`,
  `supabase/functions/_shared/fingerprint_reservation.ts` (new) + test (new),
  `supabase/functions/_shared/capture_ownership_test.ts` (new),
  `supabase/tests/batch1_security_contract_test.mjs` (new),
  `supabase/tests/fingerprint_reservation_node_test.mjs` (new).
- **iOS:** `app/ios/BankMessageShortcuts/BankMessageShortcuts.swift`\*, all 3
  `SharedCaptureStore.swift` copies\*, `app/ios/RunnerTests/RunnerTests.swift`.
- **Flutter:** `app/lib/core/session/app_session.dart`, `app/lib/features/app/app_shell.dart`,
  `app/lib/features/onboarding/restore_prompt_screen.dart`, `app/lib/features/onboarding/setup_screen.dart`,
  `app/lib/features/accounts/accounts_screen.dart`, `app/lib/features/subscriptions/bill_form_sheet.dart`\*,
  `app/lib/features/subscriptions/bill_details_sheet.dart`, `app/lib/features/subscriptions/bill_payment_attempt.dart`\* (new),
  `app/test/features/accounts/` (new), `app/test/features/onboarding/onboarding_restore_flow_test.dart` (new),
  `app/test/features/capture/capture_backend_client_test.dart` (new).
- **Migrations:** `0035_admin_authorization.sql`, `0036_capture_device_ownership.sql`,
  `0037_atomic_account_deletion.sql` + rollbacks — **already applied live and verified this session.**
- **Docs:** `docs/ADMIN_AUTHORIZATION_RUNBOOK.md`.

(\* = also touched by a later batch — see §7, mixed files.)

## 4. Batch 2 (findings #9-15) — timezone, capture health, budget-alert race, atomic queue, CHECK constraints, sender ambiguity

- `app/lib/core/utils/riyadh_time.dart`, `app/lib/domain/usecases/budget_progress_usecase.dart`\*,
  `app/lib/domain/usecases/resolve_bank_for_sender_usecase.dart`, `app/test/domain/bank_sender_resolution_usecase_test.dart`,
  `app/lib/features/settings/settings_providers.dart`\*, `app/lib/features/settings/settings_screen.dart`\*,
  `app/lib/features/capture/services/ledger_push_service.dart` (minor lint fix),
  `app/test/core/utils/` (new), `app/test/features/settings/` (new).
- iOS: all 3 `SharedCaptureStore.swift` copies\* (atomic queue locking, layered on top of Batch 1's
  persist-before-network change in the same files).
- **Migration:** `0038_check_financial_parent_constraints.sql` + rollback — **already applied live and
  verified this session** (confirmed zero pre-existing violating rows before applying).

## 5. Batch 3 (findings #16-21) — pagination, RPC wiring, backup versioning, bill-payment atomicity, rate limiting

- `app/lib/core/backup/backup_snapshot_builder.dart`, `app/lib/core/backup/restore_backup_usecase.dart`,
  `app/lib/core/di/app_providers.dart`, `app/lib/data/catalog/feature_flag_service.dart`,
  `app/lib/data/repositories/drift_bill_repository.dart`, `drift_transaction_repository.dart`,
  `routed_bill_repository.dart`, `routed_transaction_repository.dart`, `supabase_bill_repository.dart`,
  `supabase_financial_summary_service.dart`, `supabase_transaction_repository.dart`,
  `app/lib/domain/repositories/bill_repository.dart`, `transaction_repository.dart`,
  `app/lib/domain/usecases/budget_progress_usecase.dart`\* (RPC batching, layered on Batch 2's
  in-flight guard in the same file), `app/lib/features/subscriptions/bill_form_sheet.dart`\*
  (stable-id hoisting, layered on Batch 1's busy-state work), `bill_payment_attempt.dart`\* (unchanged
  by Batch 3 itself but co-located), `app/lib/features/transactions/transactions_providers.dart`,
  `transactions_screen.dart`.
- Tests: `app/test/core/backup/backup_test.dart`, `app/test/data/repository_test.dart`,
  `app/test/domain/budget_progress_usecase_test.dart`\* (concurrency test added on top of Batch 2's own
  addition to this same file).
- **Edge Functions:** `supabase/functions/_shared/capture_auth.ts` + `capture_auth_test.ts` (new),
  `link-capture-device/index.ts`, `register-device/index.ts`, `register-push-token/index.ts`,
  `sync-captures/index.ts`\* (rate-limit wiring, layered on Batch 1's `claimed_user_id` filter in the
  same file).
- **Migrations:** `0039_budget_progress_rpc_flag_and_bill_payment_rpc.sql`,
  `0040_fix_bill_payment_rpc_conflict_target.sql` (same-day hotfix),
  `0041_fix_bill_payment_rpc_paid_count_overwrite.sql` (same-day hotfix) + rollbacks —
  **all three already applied live and verified this session**, including live concurrency testing.
- **Test:** `supabase/tests/account_deletion_concurrency_node_test.mjs` (new, written during the 0040
  hotfix review, actually exercises finding #15's RPC live).

## 6. Batch 4 (findings #22-27) — privacy screens, remaining loading states, form validation, APNs diagnostics

- `app/android/app/src/main/kotlin/com/example/money_companion/MainActivity.kt` (new: `FLAG_SECURE`).
- `app/ios/Runner/AppDelegate.swift` (new: app-switcher privacy overlay + APNs failure capture).
- `app/lib/features/capture/services/native_capture_bridge.dart` (new: `ApnsRegistrationFailure` type).
- `app/lib/features/settings/settings_providers.dart`\*, `settings_screen.dart`\* (APNs diagnostics
  folded into Batch 2's existing capture-health tile in the same files).
- `app/lib/features/goals/goal_details_screen.dart` (saving-state fix), `goal_form_screen.dart`
  (busy-state guard + deadline re-validation — a disclosed, in-spirit extension beyond the literal
  brief).
- `app/lib/features/subscriptions/bill_form_sheet.dart`\* (due-date + manual-paid-amount validation,
  layered on Batches 1 and 3's earlier changes to this same file).

## 7. Batch 4 test-coverage-gap follow-up (test-only, dispatched after the review above)

- `app/test/features/goals/goal_details_screen_test.dart` (new)
- `app/test/features/goals/goal_form_screen_test.dart` (new)
- `app/test/features/subscriptions/bill_form_sheet_test.dart` (new)

Pure test additions, zero production-code changes (confirmed via `git diff --check` and diff review).
Safe as their own commit, or folded into the Batch 4 commit — either is defensible; recommend a
separate commit since it landed as a distinct, later delegation.

## 8. Mixed files requiring hunk-level staging (`git add -p`, not whole-file `git add`)

These files carry logically distinct changes from **more than one batch** and cannot be cleanly
assigned to a single commit by staging the whole file:

| File | Batches mixed | Why |
|---|---|---|
| `supabase/functions/sync-captures/index.ts` | 1, 3 | Batch 1's `claimed_user_id` ownership filter + Batch 3's rate-limit wiring |
| `app/ios/BankMessageShortcuts/SharedCaptureStore.swift` (+2 copies) | 1, 2 | Batch 1's persist-before-network state machine + Batch 2's atomic file-locking |
| `app/lib/features/subscriptions/bill_form_sheet.dart` | 1, 3, 4 | Batch 1's stable-id/busy-state, Batch 3's ID hoisting, Batch 4's date/amount validation |
| `app/lib/features/subscriptions/bill_payment_attempt.dart` | 1, 3 | Created in Batch 1; present (unchanged in substance) through Batch 3's adjacent work in the same directory — verify with a diff before assuming no Batch-3-specific edit |
| `app/lib/domain/usecases/budget_progress_usecase.dart` | 2, 3 | Batch 2's in-flight guard + Batch 3's RPC-batching closure injection |
| `app/lib/features/settings/settings_providers.dart` | 2, 4 | Batch 2's `captureHealthStatusProvider` + Batch 4's `apnsRegistrationFailure` field |
| `app/lib/features/settings/settings_screen.dart` | 2, 4 | Batch 2's capture-health tile + Batch 4's APNs-failure display branch |
| `app/test/domain/budget_progress_usecase_test.dart` | 2, 3 | Batch 2's alert-race concurrency test + Batch 3's RPC-batching tests |

For each of these, either: (a) accept a single combined commit covering both batches for that file
(simplest, defensible given both batches are part of the same overall remediation effort and both are
fully reviewed/gate-passing), or (b) use `git add -p` to split hunks precisely by batch if strict
per-batch commit purity is required. Recommend (a) — the extra precision of (b) has limited value here
since every batch in this effort is already fully reviewed and none will be reverted independently of
the others in practice.

## 9. Files that must remain unstaged

**None currently.** Finding #8 (user deletion) was correctly left as a pure decision brief with zero
destructive code — nothing exists in the tree that shouldn't be committed. Every migration that has
been applied live has also been independently gate-verified and live-tested. If the working-tree
separation above is followed, there is no file in an unsafe or half-finished state.

## Recommended commit sequence

1. Pre-existing Supabase-primary migration work (§1) — **not this task's responsibility to commit**;
   confirm with the user whether this should be committed separately/by someone else before touching
   anything else, since it long predates this remediation effort.
2. Notification wording + collapse-id fix (§2)
3. Metrics-client launch-hang fix (§2)
4. Auth/session architecture fix (§2)
5. Critical DB trigger fix, migration 0034 (§2) — already live
6. Batch 1 (§3) — already live (migrations 0035-0037)
7. Batch 2 (§4) — already live (migration 0038)
8. Batch 3 (§5) — already live (migrations 0039-0041)
9. Batch 4 (§6)
10. Batch 4 test-coverage-gap follow-up (§7)
11. Documentation (§2's docs list, or fold each doc into its most relevant commit above)

Steps 6-9 each touch at least one file listed in §8 (mixed) — stage those files' relevant hunks
alongside whichever of the two commits is landing first, and confirm the *other* batch's hunks are
included when its own commit lands (do not let a hunk get silently dropped between the two commits).
