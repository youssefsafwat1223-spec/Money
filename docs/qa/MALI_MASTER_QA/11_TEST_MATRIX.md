# 11 — Test Matrix

Related: [10_TEST_STRATEGY.md](10_TEST_STRATEGY.md), [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md), [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md), [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md).

This is the concrete scenario bank. IDs are stable and may be referenced from other documents, PR descriptions, and bug reports. Each scenario uses this template:

```
### `ID` — Title
Preconditions: ...
Steps: 1) ... 2) ... 3) ...
Expected: ...
Verify — DB: ... | Backend: ... | Flutter: ...
Logs: ...
Failure & root cause: ...
Regression test: ...
```

Where a scenario is device-only (real push delivery, real OS timing, Shortcuts automation), it is marked **[MANUAL QA REQUIRED]** per [10_TEST_STRATEGY.md](10_TEST_STRATEGY.md) §4 — do not fabricate automated coverage for these.

Notification/capture scenarios (`CAP-`, `NOTIF-`) are cross-referenced in depth in [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md) and [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md); this matrix lists them for completeness of the overall inventory but the deep-dive documents are authoritative for exact expected Supabase/Drift state per step.

---

## AUTH — Authentication

### `AUTH-001` — Google Sign-In happy path
Preconditions: fresh install, no existing session.
Steps: 1) Launch app 2) Tap "Sign in with Google" 3) Complete Google OAuth in the system browser sheet.
Expected: returns to app signed in; `Supabase.instance.client.auth.currentUser` non-null; onboarding proceeds or dashboard loads if onboarding already complete.
Verify — DB: `auth.users` row exists with matching email | Backend: GoTrue session issued, refresh token valid | Flutter: `authStateProvider` reflects signed-in state.
Logs: no error-level log from `AuthService`.
Failure & root cause: OAuth redirect fails to return to app → check URL scheme registration in `Info.plist`/`AndroidManifest.xml`.
Regression test: `test/core/auth/*` sign-in flow test with a faked GoTrue response.

### `AUTH-002` — Sign in with Apple happy path
Preconditions: fresh install, iOS only.
Steps: 1) Launch app 2) Tap "Sign in with Apple" 3) Complete Face ID/Touch ID confirmation.
Expected: signed in; if user chose "Hide My Email," a relay email is used consistently on every subsequent sign-in.
Verify — DB: `auth.users.email` is either real or Apple relay address, stable across sign-ins | Backend: GoTrue Apple provider config valid | Flutter: session persists across app restart.
Logs: none.
Failure & root cause: relay email changes between sign-ins → misconfigured Apple Service ID/team ID in Supabase Auth settings.
Regression test: N/A (provider-config issue, not code-level) — verify manually per environment.

### `AUTH-003` — Sign-out clears local session but not local financial data by default
Preconditions: signed in, has local transactions.
Steps: 1) Settings → Sign out.
Expected: session cleared; app returns to sign-in/onboarding gate; Drift data remains on-device (sign-out is not a data wipe).
Verify — DB: N/A (client-side) | Backend: refresh token revoked | Flutter: Drift file still present with prior row counts intact.
Logs: none.
Failure & root cause: if Drift data is unexpectedly cleared on sign-out, check for an accidental `db.close()`+delete call conflated with sign-out logic.
Regression test: widget test asserting `accountsProvider` count unchanged immediately after a sign-out action, before any explicit reset.

### `AUTH-004` — Session expiry mid-session triggers silent refresh
Preconditions: signed in, access token near expiry.
Steps: 1) Leave app foregrounded past token expiry 2) Trigger any Supabase call (e.g., open Accounts screen with the flag on).
Expected: `supabase_flutter` silently refreshes the token; no user-visible interruption.
Verify — DB: N/A | Backend: new access token issued, same refresh token family | Flutter: no `AuthRepoException` surfaced to UI.
Logs: none at error level.
Failure & root cause: expired-refresh-token edge case → user is signed out and must re-authenticate; verify the sign-out path (`AUTH-003`) triggers cleanly, not a crash.
Regression test: N/A (relies on SDK-level refresh behavior) — cover via manual long-session test only.

### `AUTH-005` — Biometric app-lock gate
Preconditions: biometric lock enabled in Settings.
Steps: 1) Background the app 2) Foreground it again.
Expected: a lock screen is shown requiring Face ID/Touch ID/passcode before any content is visible.
Verify — DB: N/A | Backend: N/A | Flutter: `BiometricLockGate` widget blocks the route until authenticated.
Logs: none.
Failure & root cause: gate skipped after a specific navigation path (e.g., returning from a system share sheet) → check every `AppLifecycleListener` resume hook re-triggers the gate, not just the top-level one.
Regression test: widget test simulating a lifecycle resume event and asserting the lock overlay is present.

### `AUTH-006` — QA session injection seam is debug-only
Preconditions: none.
Steps: 1) Build in release mode 2) Attempt to pass a `QA_REFRESH_TOKEN` dart-define.
Expected: the seam has no effect in a release build (or has been removed entirely per the pre-release checklist).
Verify — Flutter: `kDebugMode` guard present around the seam, or the seam is absent from the current codebase state.
Failure & root cause: seam accidentally left reachable in a release build → security review blocker, see [07_SECURITY.md](07_SECURITY.md) §6.
Regression test: static grep in the pre-release checklist ([21_CHECKLISTS.md](21_CHECKLISTS.md)) for `QA_REFRESH_TOKEN` outside a `kDebugMode` block.

---

## ONB — Onboarding

### `ONB-001` — First-run flow completes end to end
Preconditions: fresh install.
Steps: 1) Walk through all cinematic intro pages 2) Select base currency (e.g. SAR) 3) Select country 4) Complete or skip capture setup 5) Reach the dashboard.
Expected: dashboard loads with zero transactions, correct base currency shown throughout.
Verify — DB: `accounts` has a default account in the chosen currency | Backend: N/A unless flag on | Flutter: `baseCurrencyProvider` resolves to the chosen currency everywhere (goals, cards, charts, subscriptions — no hardcoded "ريال" strings).
Logs: none.
Failure & root cause: a screen still shows a hardcoded currency string → grep for literal `'ريال'`/`'SAR'` string usage outside `Currency` helper.
Regression test: widget test asserting no hardcoded currency literal renders when base currency is EGP.

### `ONB-002` — Android SMS permission grant during onboarding
Preconditions: Android device/emulator, fresh install.
Steps: 1) Reach capture setup step 2) Tap "enable SMS access" 3) Grant the OS permission prompt.
Expected: `hasSmsPermission()` returns true; capture setup step marked complete.
Verify — Flutter: `NativeCaptureBridge.hasSmsPermission()` returns true post-grant.
Failure & root cause: permission denied then re-requested without directing to system settings → must fall back to `openAppSettings()` per existing handler.
Regression test: N/A (OS-permission-dependent) — **[MANUAL QA REQUIRED]** on a real/emulated Android device.

### `ONB-003` — Android SMS permission denial does not block onboarding completion
Preconditions: Android, fresh install.
Steps: 1) Reach capture setup 2) Deny the permission prompt 3) Continue onboarding.
Expected: onboarding completes; app functions in manual-entry mode; a "complete setup" nudge appears later, dismissible/snoozable for 30 days.
Verify — Flutter: nudge dismissal persists across app restarts for 30 days.
Failure & root cause: nudge reappears every launch despite dismissal → check the snooze timestamp persistence path.
Regression test: unit test on the nudge-snooze date-comparison logic.

### `ONB-004` — iOS Shortcuts guide walkthrough
Preconditions: iOS, fresh install.
Steps: 1) Reach capture setup 2) View the in-app Shortcuts guide (`ios_shortcut_guide.dart`) 3) Follow it in the real Shortcuts app.
Expected: guide steps match the current Shortcuts app UI exactly, including the "Date Received" field instruction (added in the notification-hardening pass — see [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md) `CAP-DUP` scenarios).
Verify — Flutter: guide text renders correctly in both `ar` and `en` locales.
Failure & root cause: Apple changes the Shortcuts app UI in an OS update, guide screenshots/wording go stale → treat as a recurring maintenance item, check after every iOS major version bump.
Regression test: N/A (UI-content staleness, not logic) — **[MANUAL QA REQUIRED]** after each iOS major release.

### `ONB-005` — AI consent opt-in toggle
Preconditions: onboarding in progress.
Steps: 1) Reach the AI-consent step 2) Leave it off 3) Complete onboarding.
Expected: `ai_consent_granted` is false; no SMS is ever sent to Gemini or Google Places until explicitly turned on later in Settings.
Verify — DB: local settings row `ai_consent_granted = false` | Backend: `allowAi` never `true` in any `process-ios-sms` request body while off.
Logs: `[allowAi: false]` implicitly (absence of any Gemini-related log lines).
Failure & root cause: a stale native `ai_consent_granted` UserDefaults value from a previous install/session leaks true → `CaptureDeviceRegistrationService.syncNativeState()` must proactively clear native consent before any step that could fail, per its documented ordering.
Regression test: `test/features/capture/capture_device_registration_service_test.dart` (or equivalent) asserting consent is cleared before secret registration.

---

## ACC — Accounts

### `ACC-001` — Create first account (becomes default)
Preconditions: no existing accounts.
Steps: 1) Accounts screen → Add → fill name/currency/type → Save.
Expected: account created, `is_default = true` automatically since it's the first.
Verify — DB (flag OFF): Drift `accounts` row, `is_default = 1` | DB (flag ON): `user_accounts` row + `set_default_account` RPC called implicitly | Flutter: dashboard switcher shows the new account selected.
Failure & root cause: default not set on first account → check the "first account" branch in `create()`.
Regression test: unit test for `AccountRepository.create()` first-account-default behavior, both Drift and Supabase implementations.

### `ACC-002` — Create second account in a different currency
Preconditions: one existing default account (SAR).
Steps: 1) Add a second account, currency EGP.
Expected: second account created, `is_default = false`, dashboard now shows a second currency chip.
Verify — DB: two rows, exactly one `is_default = true` | Flutter: currency switcher shows both chips.
Regression test: existing `capture_sync_service_test.dart` "assigned to a matching currency account" pattern generalizes here.

### `ACC-003` — Set a different account as default
Preconditions: two+ accounts exist.
Steps: 1) Long-press/menu on a non-default account → "Set as default."
Expected: exactly one account has `is_default = true` afterward — the newly chosen one.
Verify — DB (flag ON): `set_default_account` RPC executed atomically (clear-then-set in one transaction); partial unique index `uidx_user_accounts_one_default` never violated | DB (flag OFF): Drift equivalent clear-then-set.
Failure & root cause: a race between two rapid "set default" taps could momentarily violate the one-default invariant if not atomic — this is exactly why the RPC exists rather than two separate client-side UPDATEs.
Regression test: concurrency test issuing two `setDefault()` calls back-to-back, asserting exactly one default remains.

### `ACC-004` — Delete a non-default account with existing transactions
Preconditions: account has transactions linked.
Steps: 1) Delete the account.
Expected: either blocked with a clear message, or transactions are reassigned/orphaned per a defined policy (confirm current behavior against `AccountRepository.delete()` before assuming).
Verify — DB: no orphaned `account_id` FK left dangling in a way that breaks a UI query.
Failure & root cause: silent orphaning causes a null-currency crash in a dashboard total — verify defensively.
Regression test: integration test creating an account + transaction, deleting the account, asserting the transactions screen doesn't crash.

### `ACC-005` — Delete the default account
Preconditions: two+ accounts, deleting the current default.
Steps: 1) Delete the default account.
Expected: another account is automatically promoted to default, or the user is prompted to choose one — never zero defaults left with other accounts present.
Verify — DB: exactly one `is_default = true` remains among surviving accounts.
Regression test: unit test covering this specific reassignment.

### `ACC-006` — Account create fails with a typed network error
Preconditions: `accounts_supabase_primary` ON for QA user, backend unreachable (airplane mode/simulated).
Steps: 1) Attempt to create an account.
Expected: a `NetworkRepoException` is caught and shown as an Arabic user-facing message via `repoExceptionMessage()`, not a raw stack trace or English exception string.
Verify — Flutter: error UI shows Arabic copy | Logs: `mapSupabaseError` classifies as `NetworkRepoException`.
Failure & root cause: an unmapped error type falls through to `UnknownRepoException` with a generic message — acceptable as a last resort, but verify the specific network case is actually caught by the network-specific branch.
Regression test: `test/domain/repo_exceptions_test.dart` case for a simulated network failure.

### `ACC-007` — Duplicate account create retried after a client timeout
Preconditions: `accounts_supabase_primary` ON.
Steps: 1) Create an account 2) Simulate the client timing out after the request actually committed server-side 3) Retry the same create call with the same idempotency key.
Expected: exactly one account row exists; the retry returns the already-created row rather than creating a duplicate.
Verify — DB: single row matching the idempotency key (`local_id`/`client_request_id`) | Backend: insert-then-23505-recover path exercised.
Regression test: existing idempotency test pattern in the repository test suite.

---

## TXN — Transactions

### `TXN-001` — Manual transaction creation, expense
Preconditions: at least one account exists.
Steps: 1) Transactions → Add → enter amount/category/account/date → Save.
Expected: transaction appears at the top of the list, dashboard total decreases by the amount in that currency.
Verify — DB: row with `type = expense`(or equivalent), correct `account_id`/`server_account_id` | Flutter: list + dashboard both reflect it without requiring a manual refresh.
Regression test: existing manual-add widget test.

### `TXN-002` — Manual transaction creation, income
Steps: same as `TXN-001` with type income.
Expected: dashboard total increases.
Regression test: mirrors `TXN-001`.

### `TXN-003` — Manual transaction creation, internal transfer
Preconditions: two accounts exist.
Steps: 1) Add a transfer transaction between the user's own two accounts.
Expected: excluded from both income and expense totals (neutral); both account balances reflect the movement if balance tracking applies.
Verify — DB: `transaction_type = transfer`, both accounts referenced correctly.
Failure & root cause: if the report screen still counts it as an expense → violates the transfer-accounting rule in [09_DATA_FLOW.md](09_DATA_FLOW.md) §1.
Regression test: report aggregation unit test asserting a transfer contributes zero to both totals.

### `TXN-004` — Edit transaction amount
Steps: 1) Open a transaction 2) Edit amount 3) Save.
Expected: dashboard/report totals recompute correctly; no duplicate row created.
Verify — DB: same row `id`, updated `amount`, `updated_at` bumped.
Failure & root cause: a previously-observed live bug produced a generic "server error" on amount edit under `transactions_supabase_primary` — if reproduced, capture the exact `PostgrestException` code/details via the (now-removed, see [17_BUG_WORKFLOW.md](17_BUG_WORKFLOW.md)) diagnostic print pattern, or add a fresh one scoped to this call only.
Regression test: `updateAmount()` repository test, both Drift and Supabase paths.

### `TXN-005` — Edit transaction category
Steps: 1) Open a transaction 2) Change category 3) Save.
Expected: category updates; if Supabase-primary, the stable category **key** is sent, and re-reading the transaction resolves back to the correct local UUID for display (see [04_DATABASE.md](04_DATABASE.md) §4.1).
Verify — DB: `category_id` is the stable key server-side | Flutter: displayed category name/icon matches, never "غير مصنّف" for a just-edited category.
Regression test: `supabase_transaction_mapping_test.dart` category round-trip case.

### `TXN-006` — Edit transaction account (move to a different account)
Steps: 1) Open a transaction 2) Change its account 3) Save.
Expected: both accounts' totals adjust correctly.
Verify — DB: `account_id`/`server_account_id` updated.
Regression test: `updateAccount()` repository test.

### `TXN-007` — Delete a transaction
Steps: 1) Open a transaction 2) Delete.
Expected: removed from the list and totals immediately; soft-deleted server-side (`deleted_at` set), hard-deleted locally.
Verify — DB (Supabase): row still exists with `deleted_at` non-null, excluded from all `isFilter('deleted_at', null)` reads | DB (Drift): row physically removed.
Regression test: `deleteTransaction()` repository test asserting subsequent reads exclude it.

### `TXN-008` — Re-add the same SMS after deleting its transaction
Preconditions: a transaction was previously deleted.
Steps: 1) Re-process the exact same SMS (manual paste or re-run capture).
Expected: allowed — a new transaction is created, not blocked as a duplicate of the deleted one.
Verify — DB: dedup hash join explicitly treats a deleted/ignored prior transaction as "not blocking."
Failure & root cause: if blocked, the dedup query's `LEFT JOIN ... WHERE (t.status IS NULL OR t.status != 'ignored')` exclusion isn't matching the actual delete semantics used by the current delete path.
Regression test: `drift_dedup_store_test.dart` (or equivalent) covering delete-then-re-add.

### `TXN-009` — Confirm a pending transaction
Preconditions: a `needs_review`/pending transaction exists.
Steps: 1) Open Smart Inbox / the confirm sheet 2) Tap confirm.
Expected: status becomes confirmed; counted in totals from that point on (if pending transactions were excluded from totals — verify current behavior).
Verify — DB: `status = confirmed`.
Regression test: `confirm()` repository test.

### `TXN-010` — Pagination beyond 1000 rows (Supabase-primary)
Preconditions: `transactions_supabase_primary` ON for a QA user with 1000+ transactions (seeded via backfill or script).
Steps: 1) Load the full transaction list.
Expected: all rows returned via paged `.range()` calls (page size 500, under PostgREST's default 1000-row cap), no skip/duplicate at page boundaries.
Verify — DB: total row count matches returned count exactly | Flutter: list length matches.
Failure & root cause: unstable ordering (no tiebreak column) causes skip/duplicate across pages when multiple rows share the same `occurred_at` — must order by `occurred_at, id` (or equivalent stable tiebreak).
Regression test: pagination test with 1500+ seeded rows sharing timestamps, asserting exact count and no duplicate IDs.

### `TXN-011` — Suspicious duplicate detection (exact match)
Preconditions: none.
Steps: 1) Add a transaction 2) Attempt to add another with identical amount, currency, merchant, card-last-4, and comparison timestamp.
Expected: second one flagged as a suspicious duplicate, not silently added as a new confirmed transaction.
Verify — DB: only one confirmed transaction; a suspected-duplicate record links to the original.
Regression test: `DuplicateTransactionDetector` unit test, exact-match case.

### `TXN-012` — Non-duplicate: same amount/merchant, different day
Steps: 1) Add a transaction 2) Add another identical in every field except the date (a day later).
Expected: both are saved as separate, non-duplicate transactions (recurring purchases like daily coffee must not be falsely flagged).
Regression test: `DuplicateTransactionDetector` unit test, distinct-timestamp case.

### `TXN-013` — Foreign/unpriced currency handling
Preconditions: a parsed SMS reports a foreign currency amount without a home-currency equivalent.
Steps: 1) Ingest such a message.
Expected: transaction stored with `foreignAmount`/`foreignCurrency` populated and the primary `amount` reflecting the home-currency placeholder per the documented `foreignUnpriced` branch — verify current exact behavior against `AddTransactionUseCase` rather than assuming.
Regression test: existing foreign-currency ingest unit test.

---

## DASH — Dashboard

### `DASH-001` — Empty state, zero transactions
Preconditions: fresh account, no transactions.
Steps: 1) Open dashboard.
Expected: a friendly empty state, not a crash or a "0" total presented as if data loaded successfully but is actually just empty by coincidence — the two must be visually distinguishable if the app also has a loading state.
Regression test: widget test for the zero-transaction dashboard state.

### `DASH-002` — Multi-currency totals shown separately
Preconditions: accounts in two currencies with transactions in each.
Steps: 1) Open dashboard.
Expected: two independent per-currency total lines; no cross-currency summation.
Regression test: widget test asserting two distinct currency labels render.

### `DASH-003` — Account switcher filters recent transactions
Steps: 1) Select a specific account in the switcher.
Expected: recent-transactions list and total reflect only that account.
Regression test: `getRecent(accountId: ...)` repository test.

### `DASH-004` — Dashboard reflects a capture import without manual refresh
Preconditions: app foregrounded.
Steps: 1) A capture (relay or direct) imports a new transaction while the app is open.
Expected: dashboard updates without the user pulling-to-refresh — driven by `ref.invalidate(dashboardDataProvider)` in `AppShell._refreshAll()`.
Regression test: covered indirectly by capture-sync integration tests plus a provider-invalidation assertion.

---

## BUD — Budgets

### `BUD-001` — Create a category budget
Steps: 1) Budgets → Add → category, monthly amount → Save.
Expected: budget appears with 0% progress initially.
Regression test: budget creation repository test.

### `BUD-002` — 75% threshold alert fires once per threshold per month
Preconditions: category budget set, spend crosses 75%.
Steps: 1) Add a transaction that pushes spend past 75% of the budget.
Expected: exactly one 75%-threshold notification for that budget/month; a second transaction that keeps spend in the 75–90% band does not re-fire it.
Verify — Flutter: notification ID incorporates year+month+threshold-bucket so it's naturally deduplicated (`94000 + (year*12+month)*10 + bucket`).
Regression test: `_checkBudgetAlert`/engagement-sync unit test asserting single-fire-per-bucket.

### `BUD-003` — 90% and 100%+ thresholds
Steps: analogous to `BUD-002` at the higher buckets.
Expected: each bucket fires independently and exactly once; crossing 100% shows an "exceeded" message with the overage amount, not the "approaching" wording.
Regression test: mirrors `BUD-002`.

### `BUD-004` — All-expenses budget vs category budget precedence
Preconditions: both an all-expenses budget and a category budget exist.
Steps: 1) Add a transaction affecting both.
Expected: both progress independently; no double-counting logic error where one budget's check accidentally reads the other's accumulated total.
Regression test: SQL-level unit test on the budget-progress query, asserting category filter is applied correctly.

### `BUD-005` — Budget progress under Supabase-primary
Preconditions: `budgets_supabase_primary` ON.
Steps: 1) View budget progress.
Expected: identical progress numbers to the Drift-backed calculation for the same underlying transactions (no drift between the two calculation paths).
Regression test: parallel test running both repository implementations against the same seeded data, asserting equal results.

---

## GOAL — Goals

### `GOAL-001` — Create a savings goal
Steps: 1) Goals → Add → target amount, name → Save.
Expected: goal appears at 0% progress.

### `GOAL-002` — Manual contribution updates progress
Steps: 1) Add a contribution to a goal.
Expected: progress bar updates; if the contribution reaches a milestone (e.g. 50%, 100%), a celebration event + notification fires exactly once per milestone.
Verify — DB: `user_goal_contributions` row (Supabase-primary) or Drift equivalent.
Regression test: milestone-notification-dedup unit test, analogous to `BUD-002`.

### `GOAL-003` — Goal completion
Steps: 1) Contribute until target reached.
Expected: goal marked complete, distinct celebration from a mid-progress milestone.

### `GOAL-004` — Delete a goal with contributions
Steps: 1) Delete a goal that has recorded contributions.
Expected: defined, non-crashing behavior for the orphaned contributions (verify against current `user_goal_contributions` cascade/soft-delete policy).

---

## RPT — Reports

### `RPT-001` — Category breakdown for the current month
Steps: 1) Open Reports → category breakdown.
Expected: matches the sum of confirmed expense transactions this month, transfers excluded.
Regression test: `categoryBreakdown()` unit test.

### `RPT-002` — Month boundary, no double counting
Preconditions: a transaction occurs at exactly `2026-08-01T00:00:00Z`.
Steps: 1) View July report 2) View August report.
Expected: the transaction appears in August only, never both.
Regression test: half-open range unit test at an exact boundary timestamp.

### `RPT-003` — Riyadh timezone local-midnight boundary
Preconditions: a transaction occurs at `2026-07-31T21:30:00Z` (which is after local midnight in `Asia/Riyadh`, UTC+3, i.e. `2026-08-01T00:30` local).
Steps: 1) View reports with Riyadh as the effective timezone.
Expected: the transaction is counted in August locally, even though its UTC date is still July 31st.
Regression test: explicit Riyadh-timezone boundary test — this is the single highest-value regression test in the reports suite given the primary user base.

### `RPT-004` — Cairo timezone boundary (different UTC offset than Riyadh)
Analogous to `RPT-003` with `Africa/Cairo` (UTC+2 or +3 depending on DST history) — must not share a hardcoded Riyadh-only offset assumption anywhere in the aggregation code.

### `RPT-005` — Refund handling in category totals
Preconditions: an expense and its matching refund both exist in the same month.
Steps: 1) View category breakdown for that category.
Expected: refund correctly offsets the expense (verify current documented behavior — refund reduces the category expense total, does not appear as a separate income line, unless the product decision states otherwise).
Regression test: refund-handling aggregation unit test.

### `RPT-006` — Merchant breakdown top-N
Steps: 1) View merchant breakdown with a `limit` parameter.
Expected: exactly `limit` merchants returned, ranked by total descending.
Regression test: `merchantBreakdown()` unit test.

### `RPT-007` — Recurring-candidate detection
Steps: 1) Seed several monthly-recurring merchant transactions 2) View recurring candidates.
Expected: the recurring merchant is surfaced; a one-off large purchase is not falsely flagged as recurring.
Regression test: `recurringCandidates()` unit test with both a true-positive and a true-negative fixture.

### `RPT-008` — Reports under 1000+ transactions (performance + correctness)
Preconditions: 1000+ seeded transactions.
Steps: 1) Load every report chart.
Expected: correct totals (matches a raw SQL sum) and acceptable load time (see [15_PERFORMANCE.md](15_PERFORMANCE.md) budgets).
Regression test: large-dataset aggregation correctness test, comparing app-computed totals against a raw reference query.

---

## SUB — Subscriptions / Bills

### `SUB-001` — Create a recurring subscription
Steps: 1) Subscriptions → Add → name, amount, recurrence, due date → Save.
Expected: appears in the list and on the "My Cards" big-brand card view if a known brand is matched.

### `SUB-002` — Bill reminder notification fires before due date
Preconditions: a subscription due in N days per the configured reminder window.
Steps: 1) Advance app time / wait for the scheduled local notification.
Expected: exactly one reminder per due cycle, not one per app resume.
Regression test: `NotificationPlanner.planScheduled()` unit test.

### `SUB-003` — Record a bill payment
Steps: 1) Mark a subscription's current cycle as paid.
Expected: a payment record is created (Supabase-primary: `user_bill_payments` row); next due date advances correctly for the recurrence type.
Regression test: bill-payment recurrence-advance unit test.

---

## PLAN — Plans

### `PLAN-001` — Create a plan and link transactions to it
Steps: 1) Create a plan 2) Link one or more existing transactions to it.
Expected: plan's spent total reflects the sum of linked transactions only.
Regression test: `user_plan_transaction_links` join-sum unit test.

### `PLAN-002` — Unlink a transaction from a plan
Steps: 1) Remove a link.
Expected: plan total decreases accordingly; the transaction itself is untouched.

---

## INBOX — Smart Inbox

### `INBOX-001` — Low-confidence parse lands in Smart Inbox
Preconditions: an SMS parses with confidence below the auto-confirm threshold.
Steps: 1) Ingest the message.
Expected: transaction created as pending, surfaced in Smart Inbox, not silently auto-confirmed.
Regression test: confidence-threshold unit test.

### `INBOX-002` — Suspicious duplicate lands in Smart Inbox, not auto-confirmed
Cross-reference: `TXN-011`, `CAP-DUP-*` in [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md).
Expected: never auto-confirmed as a new transaction — a duplicate the app cannot resolve to its original must default to pending review, not confirmed. This exact defect (orphan-duplicate captures importing as confirmed) was found and fixed in the notification/capture hardening pass.
Regression test: `capture_sync_service_test.dart` "duplicate capture with unresolved original imports as pending review."

### `INBOX-003` — Confirm from Smart Inbox
Steps: 1) Tap confirm on an inbox item.
Expected: same behavior as `TXN-009`.

### `INBOX-004` — Reject/dismiss from Smart Inbox
Steps: 1) Tap dismiss/reject.
Expected: transaction removed (or marked ignored, consistent with `TXN-008`'s re-add-allowed rule).

---

## NOTIF / CAP — Notification & Capture Pipeline

See [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md) and [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md) for the full, detailed scenario set (backend success/APNs success, APNs failure, backend timeout, backend unavailable, cloud-processing-disabled, AI-disabled, low-confidence, unknown SMS, duplicate payloadId, duplicate notification prevention, app foreground/background/killed, notification tap/dismiss, offline device, concurrent resume+tap, failed-ack+prune, rejected-SMS copy, retention cron). Every one of those is assigned a `CAP-` ID in that document and is considered part of this matrix by reference, not duplicated here.

---

## SYNC — Feature Flag & Sync Behavior

### `SYNC-001` — Per-user override wins over global rollout bucket
Preconditions: global `rollout_percent = 0` for a flag; a per-user override sets it `true` for a QA user.
Steps: 1) Sign in as the QA user 2) Check the flag's resolved value.
Expected: `true` for the QA user, `false` for every other user.
Verify — Backend: `feature_flag_overrides` row for that `user_id` only | Flutter: `FeatureFlagService.getBool()` returns true only when signed in as the QA user.
Regression test: `feature_flag_service_test.dart` override-precedence test.

### `SYNC-002` — Flag transition mid-session is not picked up until resume
Preconditions: app foregrounded, flag toggled via admin override while app stays open.
Steps: 1) Toggle the flag 2) Without backgrounding, perform an action gated by that flag.
Expected: old behavior persists until the next resume/relaunch — this is documented, expected behavior, not a bug (see [09_DATA_FLOW.md](09_DATA_FLOW.md) §7).
Regression test: N/A (documented limitation) — do not "fix" without an explicit design change request.

### `SYNC-003` — Flag transition on resume invalidates the correct providers
Steps: 1) Background the app 2) Toggle `accounts_supabase_primary` for the QA user 3) Foreground the app.
Expected: `accountsProvider`, `dashboardDataProvider` invalidated; `activeAccountIdProvider` reset to null (local vs server IDs differ across the transition).
Regression test: `AppShell._handleSupabasePrimaryFlagTransition()` unit/widget test.

### `SYNC-004` — `transactions_supabase_primary` requires `accounts_supabase_primary`
Preconditions: only `transactions_supabase_primary` overridden true, accounts flag left false.
Steps: 1) Attempt any transaction operation.
Expected: a typed `ServerRepoException('accounts_primary_required')`, not a silent fall-through to Drift with server-shaped account IDs (which would corrupt local FK assumptions).
Regression test: `RoutedTransactionRepository` guard-clause unit test.

### `SYNC-005` — Catalog delta sync after a long offline period
Preconditions: device offline for several catalog version bumps.
Steps: 1) Reconnect 2) Foreground the app.
Expected: full catch-up to the latest catalog version, not just the immediately-next delta.
Regression test: `catalog_sync_test.dart` multi-version-jump case.

---

## OFF — Offline / Network Failure

### `OFF-001` — Fully offline device, Drift-primary
Preconditions: all Supabase-primary flags OFF, airplane mode.
Steps: 1) Use the app normally (add/edit/delete transactions).
Expected: fully functional — Drift is authoritative, no network dependency for core financial operations.

### `OFF-002` — Fully offline device, Supabase-primary flag ON
Preconditions: a Supabase-primary flag ON for the QA user, airplane mode.
Steps: 1) Attempt a financial write.
Expected: a typed `NetworkRepoException` with an Arabic message — never a silent fallback to Drift while the flag says Supabase is authoritative (that would risk data divergence).

### `OFF-003` — Reconnect after an offline write attempt
Steps: 1) Attempt a write offline (fails per `OFF-002`) 2) Reconnect 3) Retry the same action.
Expected: succeeds cleanly; no leftover partial state from the failed attempt (verify no duplicate row from a retried idempotency key).

### `OFF-004` — Dirty local cache refuses to serve stale data
Preconditions: a Drift mirror write previously failed, `financial_cache_health` marked dirty for that entity type, flag now toggled OFF.
Steps: 1) Attempt to read from Drift for that entity type.
Expected: a typed `ServerRepoException('financial_cache_dirty')`, not silently stale/partial data.
Regression test: `routeFinancialOperation()` unit test for the dirty-cache-refusal branch.

### `OFF-005` — Cache repair clears the dirty flag
Preconditions: dirty cache from `OFF-004`, connectivity restored.
Steps: 1) Foreground the app (triggers `FinancialCacheRepairService.repairDirty()`).
Expected: successful repair clears the dirty flag; subsequent Drift reads (if flag is off) succeed normally.
Regression test: cache-repair-service integration test.

---

## CONF — Conflict Resolution

### `CONF-001` — Same transaction edited on two devices (Supabase-primary)
Preconditions: two devices signed in as the same user, `transactions_supabase_primary` ON on both.
Steps: 1) Edit the same transaction's amount on device A 2) Without syncing, edit its category on device B.
Expected: last-write-wins per column set in a single `UPDATE` is not typically an issue here since each device sends only its own changed fields — but verify current behavior against the actual `updateAmount`/`updateCategory` implementations (they issue targeted single-column updates, not full-row overwrites, which is the safer default). Confirm this explicitly rather than assuming.
Regression test: integration test simulating two sequential targeted updates from "different devices" against the same row, asserting both changes land.

### `CONF-002` — Duplicate default-account race across devices
Cross-reference `ACC-003`. Two devices simultaneously call "set as default" for two different accounts.
Expected: the atomic RPC + partial unique index guarantees exactly one default survives; no invariant violation regardless of interleaving.

### `CONF-003` — Capture imported on device A, later opened on device B
Preconditions: `capture_direct_supabase_write` ON, same user on two devices.
Steps: 1) A capture is direct-written to `user_transactions` from the backend (regardless of which device's Shortcut triggered it) 2) Open the app on a second device.
Expected: the transaction appears once, on both devices, correctly — since it's a single server row, not a per-device local import.

---

## PERF — Performance

See [15_PERFORMANCE.md](15_PERFORMANCE.md) for budgets. Representative scenarios:

### `PERF-001` — Cold start time budget
Expected: app reaches an interactive dashboard within the documented budget on a mid-tier reference device.

### `PERF-002` — Transaction list scroll performance with 5,000+ rows
Expected: no dropped frames beyond the documented budget; verify the list uses proper virtualization, not a fully-materialized widget tree.

### `PERF-003` — Report aggregation query time with 10,000+ transactions
Expected: within budget for both the Drift SQL path and the Supabase RPC path (once the latter exists — see [30_ROADMAP.md](30_ROADMAP.md)).

---

## SEC — Security

See [07_SECURITY.md](07_SECURITY.md) §8 checklist. Representative scenarios:

### `SEC-001` — Cross-user RLS enforcement
Preconditions: two QA users, A and B.
Steps: 1) As user A, attempt to read/write a `user_transactions` row belonging to user B via direct REST call with A's own JWT.
Expected: zero rows returned / write rejected — RLS enforced at the Postgres level regardless of any client-side bug.
Regression test: live-backend QA only (see [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md)) — this must be verified against the real database, not mocked, since it's testing Postgres's own policy enforcement.

### `SEC-002` — Capture tables are unreachable by any client credential
Steps: 1) Attempt to read `processed_captures` directly via PostgREST using an anon key and/or a signed-in user's JWT.
Expected: zero rows regardless of credential — deny-all RLS with no exception.
Regression test: live-backend QA, same rationale as `SEC-001`.

### `SEC-003` — No raw SMS text in any log line
Steps: 1) Trigger a capture with a real-shaped (but sanitized-in-transit) SMS 2) Inspect Edge Function logs.
Expected: only structured booleans/enums/counts appear, never merchant strings or raw text.
Regression test: manual/log-audit — see [07_SECURITY.md](07_SECURITY.md) §4.3, also part of the pre-release checklist.

---

## REG — Regression (see [18_REGRESSION.md](18_REGRESSION.md) for the full suite)

This section indexes regression tests that exist specifically *because* a real bug was found once. Each entry below is a pointer, not a duplicate description — see [18_REGRESSION.md](18_REGRESSION.md) for exact repro steps and the fix commit context.

- `REG-001` — Partial-index/PostgREST-upsert incompatibility (`42P10`).
- `REG-002` — Missing per-user feature-flag-override resolution.
- `REG-003` — Riverpod provider caching a stale `FeatureFlagService` instance.
- `REG-004` — Category key/local-id mismatch causing "Uncategorized" display.
- `REG-005` — Dedup-marker pruning deleting the `capture_payload:` namespace.
- `REG-006` — Concurrent `CaptureSyncService.sync()` calls double-importing a relay row.
- `REG-007` — Client-timeout dual-notification race (backend committed, local fallback also fired).
- `REG-008` — Drain-then-process native queue losing remaining messages on one failure.
- `REG-009` — Background notification action bypassing the routed repository under Supabase-primary.
- `REG-010` — Exact-timestamp-only duplicate fingerprint missing `received_at`-sourced re-runs.
- `REG-011` — Orphan "duplicate" capture importing as confirmed instead of pending.
- `REG-012` — `processed_captures` retention (`prune_processed_captures`) never scheduled.
- `REG-013` — Rejected-capture notification promising an in-app review that doesn't exist.
- `REG-014` — Global `processed_captures.payload_id` primary key allowing cross-device collision.
- `REG-015` — Concurrent duplicate capture insert returning 500 instead of an idempotent response.
- `REG-016` — `pushSent` replay race returning `false` after APNs had actually already succeeded.

---

## EDGE — Miscellaneous Edge Cases

### `EDGE-001` — Zero-amount transaction attempted
Expected: rejected by the `amount > 0` constraint server-side and equivalent client-side validation; never silently coerced to a non-zero value.

### `EDGE-002` — Non-ISO currency code attempted
Expected: rejected by `currency ~ '^[A-Z]{3}$'` server-side; client-side selection should make this unreachable in normal use, but the constraint must hold even if a future client bug bypasses the picker.

### `EDGE-003` — Extremely long merchant/note text
Expected: no truncation-induced data loss on save, no UI overflow crash on display.

### `EDGE-004` — App upgraded across a Drift schema version bump with existing data
Expected: `onUpgrade` migration case runs correctly, no data loss, `_targetSchemaVersion` matches the new value post-upgrade.
Regression test: migration test opening a fixture database at the old schema version and asserting successful upgrade.

### `EDGE-005` — Device clock significantly wrong (e.g., set far in the future)
Steps: 1) Set device clock 1 year in the future 2) Capture an SMS.
Expected: the `MAX_SMS_TIMESTAMP_FUTURE_MS`/`MAX_SMS_TIMESTAMP_PAST_MS` sanity bounds in the server parser reject an implausible SMS-body timestamp and fall back to `received_at` rather than storing a nonsensical date.
Regression test: `parseTimestamp`/`trustedSmsTimestamp` unit test in the Edge Function suite.

### `EDGE-006` — Arabic-Indic and extended Arabic-Indic digit normalization
Steps: 1) Ingest an SMS using Arabic-Indic digits (٠-٩) for the amount.
Expected: parsed identically to Western digits.
Regression test: existing digit-normalization unit test (mirrored between the Dart parser and the Swift `PreviewParser`, and the Deno deterministic parser — all three must agree).
