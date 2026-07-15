# 31 — Full Manual QA Playbook

Related: [11_TEST_MATRIX.md](11_TEST_MATRIX.md), [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md), [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md), [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md), [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md).

This is the single, sequential, start-to-finish release validation playbook. It assumes **zero prior knowledge of Mali**. Execute every section in order, on a fresh install, using a dedicated QA identity. Do not skip sections — later sections assume the database/app state left behind by earlier ones (explicitly noted where a section resets state).

If any test's actual result does not match its PASS criteria, stop, record the FAIL exactly as observed (screenshot, exact error text, exact log line), and file it per [17_BUG_WORKFLOW.md](17_BUG_WORKFLOW.md) before continuing — do not skip ahead and "come back to it."

---

## 0. Before you start

### 0.1 What you need

- A real iPhone with the app installed via `flutter run` or a signed/sideloaded build (for all iOS-specific and notification scenarios), OR an Android device/emulator (for Android-specific scenarios). Both platforms should be covered for full release validation.
- Terminal access with `curl`, `python3`, and the Supabase CLI (`supabase`) available.
- A Supabase Management API access token (`~/.supabase/access-token`, created by `supabase login`) for direct SQL verification — see [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) §1.
- The project's anon key and URL (`SUPABASE_URL`, `SUPABASE_ANON_KEY`).
- A way to view live logs: Xcode console (iOS device/simulator), `adb logcat` (Android), and `supabase functions logs <name>` or the Supabase Dashboard (Edge Functions).
- A real Apple ID capable of receiving push notifications (for APNs scenarios) and/or a real Google account (for Android/sign-in scenarios).
- If testing the iOS SMS-capture path: the Shortcuts app configured per the in-app guide (Settings → Capture Setup → "دليل الاختصار" / "Shortcuts Guide"), with **Date Received explicitly set** on the "Process Bank SMS" action (see §16 below for why this matters).

### 0.2 Safety rules for this entire playbook

- Use **one dedicated QA user** (a real or QA-provisioned Google/Apple sign-in) and **one dedicated QA device install** throughout. Never use a real user's account.
- **Global feature flags must remain OFF/0% for the entire playbook.** Every Supabase-primary flag scenario in this document uses a **per-user override** (`feature_flag_overrides`), never a global rollout change. Verify this explicitly in §0.4 before starting and again in the final cleanup (§25).
- Never run a bare `DELETE FROM <table>;` with no `WHERE` clause. Every cleanup step in this document scopes deletion by an explicit QA identifier.
- Do not enable AI consent unless a specific test case in this document calls for it — most scenarios run with AI OFF (deterministic parser only) to keep results predictable; a small number of dedicated cases test the AI-enabled path explicitly.

### 0.3 Helper snippets used throughout this document

Direct SQL check (read-only), used everywhere "check DB" appears below:

```bash
TOKEN=$(cat ~/.supabase/access-token)
q() {
  curl -s -X POST "https://api.supabase.com/v1/projects/<project-ref>/database/query" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"query\":$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"
  echo
}
```

Edge Function log tail, used everywhere "check logs" appears below:

```bash
supabase functions logs <function-name> --project-ref <project-ref>
```

### 0.4 `QA-000` — Pre-flight: confirm safe starting state
Preconditions: none.
Actions: 1) Run the flag-state query below.
```sql
select key, is_active, rollout_percent from feature_flags
where key like '%supabase_primary%' or key in ('capture_direct_supabase_write','ledger_dual_write');
```
Expected UI: N/A.
Expected DB: every row shows `is_active = false` (or `rollout_percent = 0`).
Expected Edge Function behavior: N/A.
Expected logs: N/A.
Expected notifications: N/A.
Cleanup: none.
PASS: all flags OFF globally, confirming it's safe to proceed with per-user-override testing.
FAIL indicators: any flag shows `is_active = true` with `rollout_percent > 0` — **stop immediately and report this before proceeding**; do not continue the playbook against a project with an unexpected live global rollout.

---

## 1. Fresh install & first launch

### `QA-001` — Fresh install, first launch, no session
Preconditions: app never installed on this device before, or fully uninstalled and reinstalled to guarantee no local Drift file/Keychain residue.
Actions: 1) Install the app 2) Launch it for the first time.
Expected UI: a sign-in screen or the first onboarding intro page — never a crash, never a blank white/black screen.
Expected DB: no rows exist yet for this install anywhere (no `capture_devices` row, no `auth.users` row).
Expected Edge Function behavior: none invoked yet.
Expected logs: no error-level logs.
Expected notifications: none.
Cleanup: none.
PASS: app reaches a stable, interactive first screen within the cold-start budget (~2.5s, see [15_PERFORMANCE.md](15_PERFORMANCE.md)).
FAIL indicators: crash, indefinite spinner, blank screen.

### `QA-002` — Google Sign-In
Preconditions: `QA-001` complete.
Actions: 1) Tap "Sign in with Google" 2) Complete the OAuth flow with the dedicated QA Google account.
Expected UI: returns to the app, signed in, proceeds to onboarding (or dashboard if onboarding was somehow already marked complete for this account — should not be the case on a fresh account).
Expected DB: `select id, email, created_at from auth.users where email = '<qa-email>';` returns exactly one row.
Expected Edge Function behavior: none directly (GoTrue handles this natively).
Expected logs: no error-level logs.
Expected notifications: none.
Cleanup: none (this user persists for the rest of the playbook).
PASS: signed in, `auth.users` row exists.
FAIL indicators: OAuth redirect fails to return to the app; check URL scheme registration if this happens (`Info.plist`/`AndroidManifest.xml`).

### `QA-003` — Sign in with Apple (iOS only, alternative to `QA-002`)
Preconditions: `QA-001` complete, iOS device.
Actions: 1) Tap "Sign in with Apple" 2) Complete Face ID/Touch ID confirmation.
Expected UI: signed in.
Expected DB: `auth.users` row with either a real or Apple-relay email, stable across future sign-ins with the same Apple ID.
Expected logs: none.
Expected notifications: none.
Cleanup: none.
PASS: signed in, `auth.users` row present.
FAIL indicators: relay email differs on a second sign-in attempt with the same Apple ID (Apple Service ID/team ID misconfiguration in Supabase Auth settings).

---

## 2. Onboarding

### `QA-004` — Cinematic intro pages
Preconditions: signed in, onboarding not yet complete.
Actions: 1) Swipe/tap through all intro pages to the end.
Expected UI: each page renders fully in Arabic (default locale) with no missing images/text, no crash on any transition, "Skip"/"Next" controls work.
Expected DB: N/A.
Cleanup: none.
PASS: reaches the currency/country selection step.
FAIL indicators: any page crashes, or an entrance-animation replays incorrectly on rebuild (a previously-fixed class of bug — see the app's changelog).

### `QA-005` — Base currency & country selection
Preconditions: `QA-004` complete.
Actions: 1) Select currency = SAR 2) Select country = Saudi Arabia 3) Continue.
Expected UI: proceeds to capture setup.
Expected DB: nothing written yet (this typically only takes effect once the first account is created — verify no premature `accounts` row exists yet with the wrong shape).
Cleanup: none.
PASS: selection persists to the next onboarding step.
FAIL indicators: currency/country reverts if you navigate back a step and forward again.

### `QA-006` — Android SMS permission grant [Android only]
Preconditions: `QA-005` complete, Android device.
Actions: 1) Reach capture setup 2) Tap "enable SMS access" 3) Grant the OS permission prompt.
Expected UI: capture setup step shows as complete/enabled.
Expected DB: N/A (local permission state only).
Expected logs: `adb logcat` shows no permission-related error.
Cleanup: none.
PASS: `hasSmsPermission()` (verifiable via a debug log or subsequent SMS capture actually working in §15) returns true.
FAIL indicators: permission denied then the app doesn't offer a path to system settings afterward.

### `QA-007` — Android SMS permission denial [Android only]
Preconditions: `QA-005` complete, Android device, alternate path to `QA-006` (use a second test pass or a fresh install if you already granted it in `QA-006`).
Actions: 1) Reach capture setup 2) Deny the permission prompt 3) Continue onboarding anyway.
Expected UI: onboarding completes; app is fully usable in manual-entry mode.
Cleanup: none.
PASS: onboarding does not block on permission denial; a "complete setup" nudge appears later (see `QA-008`).
FAIL indicators: onboarding gets stuck or crashes on denial.

### `QA-008` — "Complete setup" nudge snooze
Preconditions: `QA-007` state (SMS permission denied) or iOS with capture setup skipped.
Actions: 1) Reach the dashboard 2) Dismiss the "complete setup" nudge if shown 3) Force-quit and relaunch the app.
Expected UI: nudge does not reappear immediately after dismissal.
Expected DB: N/A (local preference).
Cleanup: none.
PASS: nudge stays dismissed across relaunches for its snooze window (30 days).
FAIL indicators: nudge reappears every launch despite dismissal.

### `QA-009` — iOS Shortcuts guide walkthrough [iOS only]
Preconditions: `QA-005` complete, iOS device.
Actions: 1) Reach capture setup 2) Open the in-app Shortcuts guide 3) Follow every step exactly in the real Shortcuts app: create an Automation triggered by a Message matching your bank's sender/currency keyword, Run Immediately (Notify When Run off), action = "Process Bank SMS", SMS Text = Shortcut Input, **and explicitly set the Date Received field to the message's received date** 4) Save the automation.
Expected UI: guide text is accurate against the current Shortcuts app UI, both steps and screenshots.
Cleanup: none — this automation is needed for the rest of the playbook's iOS capture scenarios.
PASS: automation saved successfully, matching the guide's described final shape exactly, with Date Received set.
FAIL indicators: guide instructions don't match the actual Shortcuts app UI (flag as a documentation-staleness bug, not a functional bug, if the underlying capture still works when done correctly); Date Received field missing from your setup will cause failures in §16's duplicate-detection tests — go back and fix this before proceeding if so.

### `QA-010` — AI consent left OFF (default path for this playbook)
Preconditions: onboarding in progress.
Actions: 1) Reach the AI-consent step 2) Leave it OFF 3) Complete onboarding.
Expected DB: local settings `ai_consent_granted = false`.
Cleanup: none.
PASS: `ai_consent_granted` is false; confirmed later in §16 that no `allowAi: true` request body is ever sent while off.
FAIL indicators: a stale native consent value leaks true from a previous install (check `syncNativeState()` proactively clears it).

### `QA-011` — Onboarding completion → empty dashboard
Preconditions: all prior onboarding steps complete.
Actions: 1) Finish onboarding.
Expected UI: dashboard loads, zero transactions, a friendly empty state (not a crash, not an ambiguous "0" that could be mistaken for a loading glitch), correct base currency (SAR) shown.
Expected DB: `accounts` (Drift) has exactly one default account in SAR.
Cleanup: none.
PASS: reaches a stable empty dashboard.
FAIL indicators: crash; wrong currency shown anywhere (grep for a hardcoded currency literal if so).

---

## 3. Accounts

### `QA-012` — Confirm the onboarding-created default account
Preconditions: `QA-011` complete.
Actions: 1) Open Settings → Accounts (or the wallet-cards "Manage Accounts" icon — **not** the dashboard "+" button, which is "Add Transaction," a common QA mistake).
Expected UI: exactly one account listed, marked default, currency SAR.
Expected DB: one Drift `accounts` row, `is_default = 1`.
Cleanup: none.
PASS: matches expected.
FAIL indicators: zero or more than one account.

### `QA-013` — Create a second account, different currency
Actions: 1) Accounts screen → Add → name "EGP Wallet", currency EGP, type = bank → Save.
Expected UI: second account appears; dashboard currency switcher now shows two chips (SAR, EGP).
Expected DB: two Drift `accounts` rows; exactly one `is_default = 1` (still the first one).
Cleanup: none — needed for later multi-currency tests.
PASS: as described.
FAIL indicators: second account accidentally becomes default; currency switcher doesn't show both.

### `QA-014` — Set a different account as default
Actions: 1) Long-press/menu on "EGP Wallet" → "Set as default."
Expected UI: "EGP Wallet" now shows the default badge; "SAR" account no longer does.
Expected DB: exactly one `is_default = 1` row, now the EGP account.
Cleanup: set SAR back as default before continuing (menu → "Set as default" on the SAR account), to keep a predictable state for later sections.
PASS: exactly one default at all times, correctly switched.
FAIL indicators: two accounts show as default simultaneously, or zero do.

### `QA-015` — Delete a non-default account with no transactions
Preconditions: create a throwaway third account "Delete Me", currency USD, not default.
Actions: 1) Delete "Delete Me".
Expected UI: removed from the list immediately.
Expected DB: row removed (Drift) or soft-deleted (Supabase-primary, not yet enabled at this point in the playbook).
Cleanup: none (already deleted).
PASS: clean removal, no crash, no orphaned default-account state.
FAIL indicators: crash; another account's default status changes unexpectedly.

---

## 4. Manual transactions

### `QA-016` — Manual expense
Preconditions: SAR account is default.
Actions: 1) Transactions tab → Add → Amount 55.00, Currency SAR, Category "مطاعم" (restaurants), Account = SAR account, today's date, note "Test lunch" → Save.
Expected UI: transaction appears at the top of the transactions list; dashboard SAR total decreases by 55.00.
Expected DB: Drift `transactions` row: amount=55.00, currency=SAR, type=expense-equivalent, category resolved to "restaurants" local id.
Cleanup: keep — used by later report tests.
PASS: as described, without requiring a manual pull-to-refresh.
FAIL indicators: dashboard doesn't update live; wrong category assigned.

### `QA-017` — Manual income
Actions: 1) Add → Amount 3000.00, SAR, type income, category "دخل" (income), account SAR → Save.
Expected UI: dashboard SAR total increases by 3000.00.
Expected DB: Drift row, income type.
Cleanup: keep.
PASS: as described.
FAIL indicators: total decreases instead of increasing (direction bug).

### `QA-018` — Internal transfer between own accounts
Preconditions: both SAR and EGP accounts exist.
Actions: 1) Add → type = transfer, from SAR account to EGP account, amount 100 SAR → Save.
Expected UI: transaction shows as a neutral transfer; **neither** the income nor expense total for the month changes because of this transaction.
Expected DB: Drift row `transaction_type = transfer`.
Cleanup: keep.
PASS: report/dashboard totals unaffected by this row (verify in §7).
FAIL indicators: transfer counted as an expense or income anywhere (violates the transfer-accounting rule, [09_DATA_FLOW.md](09_DATA_FLOW.md) §1).

### `QA-019` — Edit transaction amount
Actions: 1) Open the `QA-016` transaction 2) Change amount to 60.00 → Save.
Expected UI: list and dashboard reflect 60.00, not a duplicate second row.
Expected DB: same row `id`, `amount = 60.00`, `updated_at` newer.
Cleanup: none.
PASS: single row, updated value, totals recomputed correctly.
FAIL indicators: a "server error, try again later" toast (a previously-observed live bug under Supabase-primary — if reproduced here while flags are OFF, this is a new, higher-priority bug; file immediately).

### `QA-020` — Edit transaction category
Actions: 1) Open the `QA-016` transaction 2) Change category to "بقالة" (groceries) → Save.
Expected UI: category updates, correct icon/label, never "غير مصنّف" (Uncategorized) after a deliberate edit.
Expected DB: category FK updated.
Cleanup: none.
PASS: as described.
FAIL indicators: "غير مصنّف" shown after the edit.

### `QA-021` — Edit transaction account
Actions: 1) Open a SAR transaction 2) Change its account to the EGP account (for this test only — expect the currency mismatch to either be blocked or handled per current documented behavior; do not assume, observe and record).
Expected DB: `account_id` updated if allowed.
Cleanup: revert this change afterward.
PASS: no crash and no silently wrong total regardless of whether the app blocks or allows a cross-currency account reassignment.
FAIL indicators: crash; a total that becomes internally inconsistent (e.g., double-counted in both currencies).

### `QA-022` — Delete a transaction
Actions: 1) Open `QA-017` (the income transaction) 2) Delete.
Expected UI: removed from list and totals immediately.
Expected DB (Drift): row physically removed.
Cleanup: none (intentionally removing test data).
PASS: as described.
FAIL indicators: total not adjusted; row still appears after app restart.

### `QA-023` — Re-add the same data after deletion is allowed
Actions: 1) Re-create a transaction identical to the deleted `QA-017` (same amount/category/date).
Expected UI: added successfully, not blocked as a duplicate of the deleted one.
Expected DB: new row.
Cleanup: keep or delete, your choice — not needed further.
PASS: allowed.
FAIL indicators: blocked/flagged as a duplicate of a deleted transaction.

### `QA-024` — Exact-duplicate detection (non-deleted original)
Preconditions: `QA-016`/`QA-020` transaction still exists (60.00 SAR, groceries).
Actions: 1) Attempt to add another transaction with the exact same amount, currency, merchant/description, and date/time as an existing non-deleted transaction.
Expected UI: flagged as a suspicious duplicate (Smart Inbox / confirmation prompt), not silently added as a second confirmed transaction.
Expected DB: only one confirmed transaction exists for this data; a suspected-duplicate link references the original.
Cleanup: reject/dismiss the duplicate suggestion.
PASS: as described.
FAIL indicators: silently creates a second confirmed row.

### `QA-025` — Non-duplicate: same amount/merchant, different day
Actions: 1) Add a transaction identical to an existing one in every field except the date (a different day).
Expected UI: saved as a separate, non-duplicate transaction (recurring daily purchases, like coffee, must not be falsely flagged).
Cleanup: keep or delete.
PASS: both transactions exist independently.
FAIL indicators: falsely flagged as a duplicate.

---

## 5. Budgets

### `QA-026` — Create a category budget
Actions: 1) Budgets → Add → category "مطاعم", monthly amount 500 SAR → Save.
Expected UI: budget appears at ~0-12% progress (reflecting `QA-020`'s 60 SAR, if still categorized restaurants — adjust expectation to match actual current category).
Cleanup: keep.
PASS: created, correct initial progress.
FAIL indicators: progress miscalculated against the wrong category's transactions.

### `QA-027` — 75% budget threshold alert
Preconditions: `QA-026` budget (500 SAR limit).
Actions: 1) Add expense transactions in that category totaling to just over 375 SAR (75%) cumulative.
Expected notifications: exactly one "وصلت ٧٥٪ من ميزانيتك" notification.
Expected logs: `[Notif] showBudgetAlert type=...` (or equivalent) fired once.
Cleanup: none.
PASS: exactly one alert.
FAIL indicators: zero alerts, or more than one for the same threshold/month.

### `QA-028` — 90% and 100%+ thresholds don't re-fire the 75% alert
Actions: 1) Continue adding expenses in the same category to cross 90%, then 100%.
Expected notifications: one new alert at 90% ("وشك الاكتمال"), one new alert at 100%+ ("تجاوزت ميزانية"), and **not** a repeat of the 75% alert.
Cleanup: none.
PASS: exactly one alert per threshold bucket, ever, per month.
FAIL indicators: duplicate alerts for an already-fired threshold.

### `QA-029` — Budget alert notification ID stability across app restarts
Actions: 1) Force-quit and relaunch the app after `QA-028` 2) Add one more expense in the same category (still over 100%).
Expected notifications: no new duplicate 100%+ alert for the same month.
PASS: dedup persists across restarts (notification ID encodes year+month+threshold-bucket).
FAIL indicators: a duplicate 100%+ alert appears after relaunch.

---

## 6. Goals

### `QA-030` — Create a savings goal
Actions: 1) Goals → Add → name "رحلة", target 2000 SAR → Save.
Expected UI: goal at 0% progress.
Cleanup: keep.
PASS: created correctly.

### `QA-031` — Contribution updates progress, 50% milestone
Actions: 1) Add a contribution of 1000 SAR to the goal.
Expected UI: progress shows 50%; a milestone celebration/notification fires exactly once.
Expected DB: contribution recorded (Drift; or `user_goal_contributions` later once Supabase-primary is tested for goals).
Cleanup: keep.
PASS: exactly one 50% milestone notification.
FAIL indicators: no notification, or more than one.

### `QA-032` — Goal completion (100%)
Actions: 1) Add a further 1000 SAR contribution.
Expected UI: goal marked complete; celebration visually/behaviorally distinct from the 50% milestone (not the identical animation/copy).
Cleanup: keep or delete.
PASS: as described.
FAIL indicators: no distinction between mid-progress and completion celebrations.

---

## 7. Subscriptions / Bills

### `QA-033` — Create a recurring subscription
Actions: 1) Subscriptions → Add → name "Netflix", amount 45 SAR, monthly recurrence, due date = 5 days from today → Save.
Expected UI: appears in the subscriptions list; if "Netflix" matches a known brand, appears with brand styling on the "My Cards" screen.
Cleanup: keep.
PASS: created correctly, correct due date shown.

### `QA-034` — Bill reminder notification timing
Preconditions: `QA-033`, reminder window configured (check Settings for the exact configured lead time, commonly a few days before due).
Actions: 1) Wait for or simulate reaching the reminder window (advancing device time is acceptable for QA only, never on a device with real financial reminders relied upon).
Expected notifications: exactly one reminder for this due cycle.
Cleanup: revert device time if changed.
PASS: exactly one reminder, not one per app resume within the window.
FAIL indicators: a reminder fires on every single app open during the window.

### `QA-035` — Record a bill payment
Actions: 1) Mark the current cycle as paid.
Expected UI: due date advances to next month automatically.
Expected DB: a payment record created.
Cleanup: keep.
PASS: correct next-due-date computed for a monthly recurrence.
FAIL indicators: due date computed incorrectly (e.g., skips a month, or doesn't advance).

---

## 8. Plans

### `QA-036` — Create a plan and link a transaction
Actions: 1) Plans → Add → name "Test Plan" 2) Link the `QA-018` transfer or any existing transaction to it.
Expected UI: plan's spent total reflects only the linked transaction(s).
Cleanup: keep.
PASS: correct linked-total calculation.

### `QA-037` — Unlink a transaction from a plan
Actions: 1) Remove the link created in `QA-036`.
Expected UI: plan total decreases accordingly; the transaction itself remains untouched (still visible normally in the transactions list).
Cleanup: none.
PASS: as described.
FAIL indicators: the transaction itself gets deleted or modified by the unlink action.

---

## 9. Smart Inbox

### `QA-038` — Low-confidence parse lands in Smart Inbox
Preconditions: this is naturally exercised in §15/§16 (SMS capture); if testing standalone, use the manual-paste screen with an ambiguous/low-information message.
Actions: 1) Paste an ambiguous message that yields low parse confidence.
Expected UI: transaction created as pending, appears in Smart Inbox, **not** auto-confirmed.
Cleanup: confirm or dismiss it.
PASS: lands as pending review.
FAIL indicators: auto-confirmed despite low confidence.

### `QA-039` — Confirm from Smart Inbox
Actions: 1) Tap confirm on a pending item.
Expected DB: `status = confirmed`.
Cleanup: none.
PASS: as described.

### `QA-040` — Dismiss/reject from Smart Inbox
Actions: 1) Tap dismiss on a different pending item.
Expected UI: removed from the inbox.
Cleanup: none.
PASS: removed cleanly, and re-adding the same data later is allowed (per `QA-023`'s rule).

---

## 10. Reports & Dashboard aggregation

### `QA-041` — Category breakdown matches manual sum
Actions: 1) Open Reports → category breakdown for the current month.
Expected UI: "بقالة"/"مطاعم" totals match the manual sum of your test transactions from §4 in that category (transfers excluded per `QA-018`).
PASS: numbers match exactly.
FAIL indicators: transfer amount leaking into the total.

### `QA-042` — Month boundary, no double counting
Actions: 1) Add a transaction dated exactly at the first moment of next month (if the date picker allows a precise time; otherwise add one dated the 1st and one dated the last day of the current month) 2) View both months' reports.
Expected UI: each transaction appears in exactly one month, never both, never neither.
PASS: as described.
FAIL indicators: a transaction counted in both months or missing from both.

### `QA-043` — Timezone boundary (Riyadh)
Preconditions: device timezone set to `Asia/Riyadh` (or verify the app's effective timezone handling if device-timezone-independent).
Actions: 1) Add a transaction with a UTC timestamp that is still the previous UTC day but already past local midnight in Riyadh (e.g., 21:30 UTC, which is past midnight local time the next day).
Expected UI: the transaction appears in the **local** next-day/next-month report, not the UTC one.
PASS: local-time boundary respected.
FAIL indicators: transaction appears under the UTC date instead of the local date.

### `QA-044` — Multi-currency totals shown separately
Actions: 1) With both SAR and EGP transactions present, view the dashboard.
Expected UI: two independent per-currency total lines — no cross-currency conversion/summation.
PASS: as described.
FAIL indicators: a single merged/converted total appears (this would be a scope violation, not just a bug — see [02_PROJECT_DISCOVERY.md](02_PROJECT_DISCOVERY.md) §6).

### `QA-045` — Merchant/recurring breakdown
Actions: 1) Add the same merchant name to 3+ transactions across different months 2) View the recurring-candidates/merchant-breakdown report.
Expected UI: the recurring merchant is surfaced; a genuine one-off large purchase elsewhere is not falsely flagged as recurring.
PASS: as described.

---

## 11. Settings

### `QA-046` — Notification preference toggles
Actions: 1) Settings → Notifications → toggle off "Budget Alerts" 2) Trigger a new budget threshold crossing.
Expected notifications: none for budgets while toggled off; other notification types unaffected.
Cleanup: toggle back on afterward.
PASS: toggle correctly gates only its own notification type.

### `QA-047` — Quiet hours (non-capture notifications)
Actions: 1) Enable quiet hours covering the current time 2) Trigger a budget alert.
Expected notifications: the alert is scheduled for after quiet hours end, not shown immediately.
Cleanup: disable quiet hours afterward.
PASS: as described.
FAIL indicators: a capture/SMS notification is also delayed by quiet hours — capture notifications must always be immediate regardless (see [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md) §5), verify this specifically with a capture test from §15/§16 during the quiet-hours window.

### `QA-048` — Biometric app-lock
Actions: 1) Enable biometric lock 2) Background the app 3) Foreground it again.
Expected UI: a lock screen requiring Face ID/Touch ID/passcode appears before any content is visible.
Cleanup: disable afterward if it interferes with later tests, or keep and authenticate each time.
PASS: gate appears on every resume.
FAIL indicators: gate skipped after returning from a specific navigation path (e.g., a system share sheet).

### `QA-049` — Base currency display consistency
Actions: 1) Change base currency in Settings (if supported as a post-onboarding change) or note current base currency 2) Navigate through Goals, Subscriptions ("My Cards"), Reports charts.
Expected UI: every screen shows the correct currency symbol/code — no hardcoded leftover string from another currency.
PASS: consistent everywhere.

---

## 12. Achievements / Gamification

### `QA-050` — Passive badge unlock
Actions: 1) Perform whatever qualifying activity unlocks a badge (e.g., first transaction, a streak of daily activity — check current badge criteria).
Expected notifications: exactly one achievement notification per badge, ever.
Cleanup: none.
PASS: single-fire per badge.
FAIL indicators: repeated notifications for an already-unlocked badge.

### `QA-051` — Daily streak reminder
Preconditions: no activity recorded today.
Actions: 1) Wait until the evening reminder time (or verify via the scheduled-notification list if inspectable).
Expected notifications: one streak reminder if no activity today; none if activity already happened today.
PASS: correctly conditioned on `hasActivityToday`.

---

## 13. Backup / Restore

### `QA-052` — Export a backup
Actions: 1) Settings → Backup → Export.
Expected UI: success confirmation.
Expected DB: a `backups` metadata row created for this user; an object appears in the user's private path within the `backups` Storage bucket.
Cleanup: keep this backup for `QA-053`.
PASS: as described.
FAIL indicators: export reports success but no Storage object/`backups` row actually exists (verify directly, don't trust the UI toast alone).

### `QA-053` — Restore from backup
Preconditions: `QA-052` complete; make a note of current transaction count first.
Actions: 1) Add one throwaway transaction (to later verify it disappears) 2) Settings → Backup → Restore → select the `QA-052` backup.
Expected UI: app reopens/reloads with the restored data.
Expected DB: transaction count matches the pre-`QA-052` state (the throwaway transaction from this step is gone; everything up to the backup point is present).
Cleanup: none.
PASS: exact restoration to the backup's point-in-time state.
FAIL indicators: data loss beyond the intended restore point, or a corrupted/unopenable database after restore (if this happens, this is the exact scenario in [25_DISASTER_RECOVERY.md](25_DISASTER_RECOVERY.md) §2 — do not panic-delete anything, follow that procedure).

---

## 14. Android direct SMS capture [Android only]

### `QA-054` — Deterministic parse, clear debit SMS
Preconditions: `QA-006` (SMS permission granted).
Actions: 1) Send/simulate an incoming SMS to the test device from a registered bank sender, text: `"شراء بمبلغ 55.00 SAR لدى CARREFOUR بطاقة *4321"`.
Expected UI: transaction appears automatically within seconds, confirmed status, category "بقالة" (groceries, via merchant match), amount 55.00 SAR.
Expected logs: `adb logcat` shows the background handler processing the message, no error.
Expected notifications: a light capture notification (not a review request, since this is high-confidence).
Cleanup: keep or delete the resulting transaction.
PASS: exactly one transaction, correct fields, single notification.
FAIL indicators: no transaction created; wrong amount/category; duplicate transaction.

### `QA-055` — Deterministic parse, credit/deposit SMS
Actions: 1) Simulate: `"تم إيداع مبلغ 500.00 SAR في حسابك"`.
Expected UI: transaction created as income, confirmed.
PASS: correct direction (credit → income), correct amount.
FAIL indicators: miscategorized as an expense.

### `QA-056` — Ignored/non-transaction SMS
Actions: 1) Simulate an OTP message: `"رمز التحقق الخاص بك هو 123456"`.
Expected UI: no transaction created.
Expected notifications: none (ignored keyword match).
PASS: correctly ignored.
FAIL indicators: an OTP is mistakenly parsed as a transaction.

### `QA-057` — Ambiguous SMS → pending/needs review
Actions: 1) Simulate a message with an amount but ambiguous/missing direction wording.
Expected UI: transaction created as pending, review notification shown, appears in Smart Inbox.
PASS: not auto-confirmed.
Cleanup: confirm or dismiss.

### `QA-058` — Arabic-Indic digit normalization
Actions: 1) Simulate: `"شراء بمبلغ ٧٥.٠٠ SAR لدى STARBUCKS"` (Arabic-Indic digits).
Expected UI: parsed identically to Western digits — amount 75.00.
PASS: correct amount parsed.
FAIL indicators: amount parsed incorrectly or transaction not created at all.

---

## 15. iOS Shortcuts + backend capture relay [iOS only]

For every scenario below, cloud processing must be enabled in Settings (Capture Setup), and the device registered/linked per `QA-009`. AI stays OFF unless a specific test says otherwise.

### `QA-059` — Backend success + APNs success (the golden path)
Preconditions: device has a valid registered APNs token (confirm via Settings → Capture Setup showing "push enabled" or equivalent).
Actions: 1) Trigger the Shortcuts automation with SMS text: `"شراء عبر مدى بمبلغ 42.50 SAR لدى COFFEE HOUSE بطاقة *1234"`, sender = your configured test bank sender, Date Received = now.
Expected UI: exactly **one** push notification: title "تم رصد عملية شراء 🛒", body containing amount 42.50 SAR, merchant "COFFEE HOUSE", card ****1234, category, time.
Expected DB: `processed_captures` row for this `install_id_hash`+payload, `status = processed`, `apns_push_sent_at` non-null. Check:
```sql
select payload_id, status, apns_push_sent_at from processed_captures
where install_id_hash = '<your qa install_id_hash>' order by created_at desc limit 1;
```
Expected Edge Function behavior: `process-ios-sms` returns `pushSent: true`.
Expected logs: `sms_parse_result` (hasAmount=true, hasCurrency=true), `capture_stored` (status=processed), `apns_sent`, `process_ios_sms_complete`.
Cleanup: none yet — needed to verify import in `QA-063`.
PASS: exactly one notification, matching content.
FAIL indicators: two notifications; wrong amount/merchant; no notification at all.

### `QA-060` — APNs failure → local backend-parsed fallback
Preconditions: temporarily make the device's push token invalid (e.g., toggle notification permission off then trigger, or use a device known to have no valid token registered).
Actions: 1) Trigger the automation with a new, distinct SMS: `"شراء بمبلغ 30.00 SAR لدى NOON"`.
Expected UI: exactly one **local** notification (not from APNs), built from the backend's actual parsed result.
Expected DB: `processed_captures` row, `apns_push_sent_at` null, `apns_push_error` populated.
Expected logs: `apns_skipped` or `capture_apns_failed`.
PASS: exactly one notification, no second one appears later when the app is opened.
FAIL indicators: two notifications; zero notifications.

### `QA-061` — Backend unreachable / cloud processing disabled → PreviewParser fallback
Preconditions: disable cloud processing in Settings, or put the device in airplane mode for this one trigger.
Actions: 1) Trigger the automation with: `"شراء بمبلغ 20.00 SAR لدى EXTRA"`.
Expected UI: exactly one local notification built by the on-device Swift `PreviewParser` (title "تم رصد عملية شراء 🛒" if high-confidence, matching the same visual style).
Expected DB: no `processed_captures` row created (backend never reached); the message is durably queued in the App Group (verify it imports once the app opens, `QA-063`).
PASS: exactly one notification; message still recoverable once online/app opened.
FAIL indicators: message lost entirely; two notifications.
Cleanup: re-enable cloud processing before continuing.

### `QA-062` — Rejected (non-transaction) SMS, honest copy
Actions: 1) Trigger the automation with: `"عرض خاص: خصم 50% على جميع المنتجات"` (a marketing-style message from the registered sender, not a real transaction).
Expected UI: a "قِرش رصد رسالة بنك" notification whose body instructs pasting manually ("الصقها يدوياً في قرش لإضافتها") — must **not** claim an in-app review exists.
Expected DB: `processed_captures` row, `status = rejected`.
PASS: copy matches the honest wording exactly; tapping it does not lead to an empty/confusing review screen.
FAIL indicators: copy still says "افتح قرش لمراجعتها" (promising a review that doesn't exist) — this is regression `REG-013`, see [18_REGRESSION.md](18_REGRESSION.md).

### `QA-063` — Open the app, drain all pending relay/queue captures
Preconditions: `QA-059` through `QA-062` all triggered.
Actions: 1) Open the app (from the home screen, not via a notification tap).
Expected UI: transactions from `QA-059`, `QA-060`, `QA-061` all appear in the transactions list, imported exactly once each; `QA-062`'s rejected message creates no transaction.
Expected DB: `processed_captures` rows for the acked payloads (`QA-059`/`QA-060`) are now deleted (acked via `sync-captures`); Drift/local transactions exist for all three real ones.
Expected Edge Function behavior: `sync-captures` called, returns the pending rows, then acked.
Expected logs: `[Capture] consumeSharedInput: N messages` and per-message `[Capture] disposition=...`.
PASS: exactly 3 new transactions (from `QA-059`/`QA-060`/`QA-061`), zero duplicates, `QA-062` created none.
FAIL indicators: any duplicate; any missing transaction; a crash mid-import (verify remaining messages still process if one fails — see [18_REGRESSION.md](18_REGRESSION.md) `REG-008`).

### `QA-064` — Duplicate same payload (automation misfire simulation)
Actions: 1) Trigger the exact same automation run twice in immediate succession on the exact same SMS (same Date Received both times, if your Shortcuts flow allows re-running identically).
Expected UI: at most one notification presence (collapsed), never two independent banners.
Expected DB: exactly one `processed_captures` row (same `payload_id`), the second call's response has `idempotent: true`.
PASS: single transaction after import.
FAIL indicators: two transactions.

### `QA-065` — Duplicate detection WITHOUT Date Received set
Preconditions: temporarily edit your Shortcuts automation to remove/blank the Date Received field (revert after this test).
Actions: 1) Trigger the automation twice on the identical SMS text, a few minutes apart.
Expected UI: the second run is flagged as a suspicious duplicate (bucketed fingerprint tolerance on the server), landing in Smart Inbox for review — **never** silently imported as a second confirmed transaction.
Expected DB: `capture_fingerprints` shows a match on the second call; `processed_captures.status = duplicate` for the second payload.
PASS: exactly one confirmed transaction; the second is a reviewable duplicate.
FAIL indicators: two confirmed transactions (regression `REG-010`).
Cleanup: restore Date Received in your Shortcuts automation before continuing to later sections.

### `QA-066` — Duplicate-status capture with unresolved original → pending, not confirmed
This is difficult to force precisely on a single device (it requires the local dedup marker for the original to be genuinely missing). Best-effort approach: 1) Trigger a capture 2) Before opening the app to import it, uninstall and reinstall the app (clearing local Drift/markers) 3) Trigger an SMS that the backend will flag as a duplicate of the now-orphaned original 4) Open the app.
Expected UI: the duplicate-flagged capture imports as **pending**, surfaced for review — never auto-confirmed.
PASS: pending, not confirmed.
FAIL indicators: silently confirmed (regression `REG-011`).
Note: if this exact scenario is impractical to force on your device, treat the automated regression test (`capture_sync_service_test.dart`, "duplicate capture with unresolved original imports as pending review") as the authoritative bar for this behavior and record this manual attempt as best-effort/inconclusive rather than a false PASS.

### `QA-067` — Backend timeout → at most one notification
This is inherently hard to force exactly (see [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md) §3). Best-effort: 1) Enable AI consent temporarily 2) Trigger a capture under a deliberately poor network connection (e.g., very low bandwidth Wi-Fi) to increase the chance of the server round-trip approaching the 8s client budget.
Expected UI: never more than one notification total for this one SMS.
Expected logs: if a retry occurred, a second `process-ios-sms` call for the same `payloadId` logging `capture_idempotent_replay`.
PASS: at most one banner, ever, for this SMS.
FAIL indicators: two banners (regression `REG-007` — if reproduced, this is a serious regression, escalate immediately).
Cleanup: disable AI consent again afterward unless a later test needs it.

### `QA-068` — AI-assisted parse (AI enabled)
Preconditions: enable AI consent in Settings.
Actions: 1) Trigger the automation with an SMS the deterministic parser alone might under-classify, e.g. an unusual phrasing your bank sometimes uses.
Expected DB: `processed_captures.parsed.parserSource = 'ai_hybrid'` when AI actually contributed; request body sent `allowAi: true`.
Expected logs: `sms_parse_result` shows `parserSource: ai_hybrid` (or `deterministic` if the deterministic parser alone was already sufficient and AI wasn't needed — both are valid outcomes, verify which happened and that it's sensible).
PASS: parse succeeds; no raw SMS text appears in any Edge Function log line (§0.3's log-tail command — verify directly).
FAIL indicators: raw SMS text or merchant PII appears in a log line — this is a security-review blocker, escalate immediately per [07_SECURITY.md](07_SECURITY.md).
Cleanup: disable AI consent again unless subsequent tests need it.

### `QA-069` — Notification tap routing (APNs push)
Preconditions: `QA-059`'s notification still present (or trigger a fresh one).
Actions: 1) Tap the push notification.
Expected UI: app opens and routes directly to that transaction's detail screen (or Smart Inbox if it was a needs-review capture).
PASS: correct routing.
FAIL indicators: opens to a blank dashboard with no routing.

### `QA-070` — Notification tap routing (local fallback)
Preconditions: `QA-060` or `QA-061`'s local fallback notification.
Actions: 1) Tap it.
Expected UI: same correct routing behavior as `QA-069`.
PASS: as described (this requires the fallback notification to carry routing `userInfo` — see [18_REGRESSION.md](18_REGRESSION.md), a previously-missing capability).
FAIL indicators: tapping opens the app with no specific routing (pre-hardening behavior — regression if seen now).

### `QA-071` — Background confirm action → server row confirmed [requires §17 flag override]
See §17 (`QA-084`) — this scenario specifically depends on `transactions_supabase_primary` being on for the QA user, so it's grouped there rather than here.

### `QA-072` — Notification dismissed (no action)
Actions: 1) Receive any capture notification 2) Swipe it away without tapping.
Expected UI/DB: no change in transaction status caused by the dismissal itself; the transaction (if one was created) remains exactly as it was.
PASS: dismissal has zero side effects beyond removing the banner.

### `QA-073` — App killed entirely, then capture, then reopen
Actions: 1) Force-quit the app completely 2) Trigger the automation with a new SMS 3) Reopen the app from the home screen (not via notification).
Expected UI: transaction imported exactly once on reopen.
PASS: single transaction present.
FAIL indicators: duplicate; missing.

### `QA-074` — Foreground capture (app already open)
Actions: 1) With the app open in the foreground, trigger the automation.
Expected UI: the transaction appears live in the list without a manual refresh; observe (record, don't assume) whether an in-app banner also shows.
PASS: no duplicate transaction; list updates live.

### `QA-075` — Concurrent resume + notification tap
Actions: 1) Trigger a capture 2) As the push arrives, rapidly background/foreground the app while also tapping the notification, trying to force both a resume-triggered sync and a tap-triggered sync to overlap.
Expected DB: exactly one transaction, regardless of the exact interleaving (protected by the in-flight-sync guard).
PASS: no duplicate.
FAIL indicators: two transactions from one SMS (regression `REG-006`).

### `QA-076` — Rate limit boundary (best-effort, do not abuse the live project)
This test is optional and should only be run against a QA-scoped install, with awareness that it deliberately approaches an abuse-prevention limit. Actions: 1) Trigger 10–20 rapid captures in a short burst (well under the 300/day cap — do not actually attempt to hit 300 against the live project casually).
Expected DB: `capture_rate_limits.call_count` increments correctly and atomically for every attempt, no undercounting.
PASS: count matches the number of attempts exactly.
Cleanup: none needed at this small scale.

---

## 16. Feature-flag-gated Supabase-primary cutover (per entity, per-user override only)

**Global flags must remain OFF throughout this entire section.** Every test below uses a per-user override:

```sql
insert into feature_flag_overrides (user_id, key, enabled)
values ('<qa_user_id>', '<flag_key>', true)
on conflict (user_id, key) do update set enabled = true;
```

### `QA-077` — Enable `accounts_supabase_primary` override, verify cutover
Actions: 1) Set the override for the QA user 2) Force-quit and relaunch the app (flag transitions are only picked up on resume/cold-start, by design) 3) Create a new account.
Expected UI: works identically to the Drift-backed flow from the user's perspective.
Expected DB: a `user_accounts` row created directly in Supabase (not just Drift); a Drift mirror row also exists post-success.
PASS: account created server-side, mirrored locally.
FAIL indicators: account only exists in Drift (flag not actually taking effect); a raw/English error surfaces instead of an Arabic typed message on any induced failure.

### `QA-078` — Set default account via RPC
Actions: 1) With the flag on, set a different account as default.
Expected DB: `select * from user_accounts where user_id = '<qa_user_id>' and is_default = true;` returns exactly one row, matching the newly chosen account — verify the `set_default_account` RPC path, not a raw client UPDATE.
PASS: exactly one default, atomically switched.

### `QA-079` — Account create idempotency on retry
Actions: 1) With the flag on, simulate a retried create (same idempotency key twice — e.g., by triggering the app's own retry path if reachable, or via a direct REST call with a repeated `local_id`).
Expected DB: exactly one row for that key, not two.
PASS: idempotent.

### `QA-080` — Enable `transactions_supabase_primary` override (requires accounts flag also on)
Actions: 1) Set the override 2) Relaunch 3) Create a manual transaction.
Expected DB: `user_transactions` row created server-side, Drift mirror updated.
PASS: as described.
FAIL indicators: attempting this with only the transactions flag on (accounts flag off) — expected to be explicitly blocked with a typed `accounts_primary_required` error, not silently misrouted; verify this guard specifically.

### `QA-081` — Transaction edit/delete under Supabase-primary
Actions: 1) Edit the amount of the `QA-080` transaction 2) Delete a different one.
Expected DB: edit updates the same server row (no duplicate); delete sets `deleted_at` server-side (soft delete) while disappearing from the Drift-mirrored list.
PASS: as described.
FAIL indicators: the previously-observed "server error" symptom on amount edit — if reproduced, escalate immediately as a high-priority regression re-check.

### `QA-082` — Pagination correctness at scale
Preconditions: seed 1000+ transactions for the QA user under this flag (via a script/backfill, not manually one at a time).
Actions: 1) Load the full transaction list.
Expected UI: total count matches a direct SQL count exactly, no skipped or duplicated rows.
PASS: exact match.
FAIL indicators: count mismatch (check for a missing stable tiebreak in the pagination ordering).

### `QA-083` — Cache mirror failure + repair
Actions: 1) Simulate a mirror-write failure (e.g., temporarily block local DB writes) immediately after a successful Supabase write 2) Confirm the operation still reports success to the user 3) Restore normal local DB access 4) Relaunch the app.
Expected DB: `financial_cache_health` marked dirty for `transactions` immediately after the simulated failure; cleared after the next successful resume's repair pass.
PASS: user-visible success preserved throughout; dirty flag correctly set then cleared.
FAIL indicators: the user sees an error despite Supabase having actually succeeded.

### `QA-084` — Background confirm action → server row confirmed
Preconditions: `transactions_supabase_primary` override ON.
Actions: 1) Trigger a capture that lands as `needs_review` 2) Without opening the app, tap "تأكيد ✓" directly from the notification 3) Open the app afterward.
Expected DB: the corresponding `user_transactions` row shows confirmed status — not silently reverted to pending on next load.
PASS: server row is authoritatively confirmed.
FAIL indicators: reverts to pending after opening the app (regression `REG-009`).

### `QA-085` — Offline write attempt under Supabase-primary
Actions: 1) With the flag on, enable airplane mode 2) Attempt to add a transaction.
Expected UI: a clear Arabic error message (typed `NetworkRepoException`), not a silent success, not a raw English exception.
Cleanup: disable airplane mode.
PASS: as described.
FAIL indicators: silently falls back to writing only Drift while claiming success (would risk data divergence once back online).

### `QA-086` — Dirty local cache refuses stale reads when flag is OFF
Preconditions: from `QA-083`'s dirty state (if still dirty) or force it again, then set the override back to OFF.
Actions: 1) Attempt to read transactions with the flag off and the cache still marked dirty.
Expected UI: a typed error rather than silently stale/partial data.
PASS: as described.
Cleanup: repair the cache (relaunch with connectivity) before continuing.

### `QA-087` through `QA-091` — Repeat the accounts/transactions pattern for remaining entities (as each becomes available)
For each of `budgets_supabase_primary`, `goals_supabase_primary`, `subscriptions_supabase_primary`, `plans_supabase_primary`, `smart_inbox_supabase_primary`: repeat the shape of `QA-077`/`QA-080` (enable per-user override, relaunch, create/edit/delete the entity, verify server-side row + Drift mirror, verify typed error handling offline, verify provider invalidation on the flag transition). Record each as its own dated test run since these flags are not all backed by a complete implementation yet — see [30_ROADMAP.md](30_ROADMAP.md) Phase 4 for current status; if an entity's Supabase-primary path isn't implemented yet, mark this section **NOT APPLICABLE (Phase 4 pending)** rather than a FAIL.

### `QA-092` — Flag transition mid-session is not picked up until resume (documented, expected)
Actions: 1) With the app open and foregrounded, toggle any per-user override 2) Without backgrounding, perform an action gated by that flag.
Expected UI: old behavior persists until the next resume/relaunch.
PASS: this is correct, expected behavior — do not file this as a bug.

### `QA-093` — Disable all overrides, confirm clean fallback
Actions: 1) Remove every override row for the QA user 2) Relaunch.
Expected DB/UI: app falls back to Drift-primary for every entity, all previously-synced data still visible (via the mirror), no crash.
PASS: clean fallback.
Cleanup: this is itself the cleanup step for this whole section — confirm no override rows remain: `select * from feature_flag_overrides where user_id = '<qa_user_id>';` should return zero rows.

---

## 17. Individual Edge Function verification

Run each of these as a direct REST call per [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) §8's pattern, independent of the running app, to isolate backend-only issues from client issues.

### `QA-094` — `register-device`
Actions: `POST /functions/v1/register-device` with a fresh `installId`.
Expected: 200, returns a `deviceSecret`.
Expected DB: `capture_devices` row created, `user_id` null.
PASS: as described.

### `QA-095` — `link-capture-device`
Actions: `POST /functions/v1/link-capture-device` with the QA user's JWT, the same `installId`/`deviceSecret`.
Expected: 200.
Expected DB: `capture_devices.user_id` now set to the QA user's id.
PASS: as described.

### `QA-096` — `register-push-token`
Actions: `POST /functions/v1/register-push-token` with a fake/test token and environment `sandbox`.
Expected: 200.
Expected DB: `capture_devices.apns_token`/`apns_environment` updated (if this table stores it directly, or wherever the current schema places it).
PASS: as described.

### `QA-097` — `process-ios-sms` direct call
Actions: `POST /functions/v1/process-ios-sms` with a QA-prefixed `payloadId` and a clear transaction SMS.
Expected: 200, `capture.status = processed`, correct parsed fields.
PASS: as described. (Full scenario coverage already in §15 via the real device path — this is the backend-only isolation check.)

### `QA-098` — `sync-captures` direct call
Actions: `POST /functions/v1/sync-captures` with the QA device's credentials.
Expected: 200, returns pending captures array; a follow-up call with `ackPayloadIds` deletes them.
PASS: as described.

### `QA-099` — `parse-sms`
Actions: call with the QA user's JWT and a sample SMS body (this is the in-app AI-assist path used by manual paste/Android, distinct from the iOS relay's own AI call).
Expected: 200, parsed result.
PASS: as described.

### `QA-100` — `enrich-merchant`
Actions: call with an unknown merchant name.
Expected: 200, a category suggestion or `matched: false`.
Expected DB: if matched and `write: true`, a `merchant_keywords`-equivalent row is written for future catalog sync.
PASS: as described.

### `QA-101` — `bank-discovery`
Actions: call with a plausible new bank-sender pattern.
Expected: 200, a proposed bank profile or a "no match" result.
PASS: as described.

### `QA-102` — `catalog-delta` / `catalog-flags` / `catalog-versions` / `catalog-announcements`
Actions: call each with the anon key.
Expected: 200, current catalog data returned; a `catalog_versions` bump is reflected on a subsequent call after any admin-panel edit.
PASS: as described.

### `QA-103` — `parser-test` (admin-panel-facing)
Actions: call with an admin session, a sample regex rule and test text.
Expected: 200, match/no-match result matching manual regex evaluation.
PASS: as described.

---

## 18. Error scenarios

### `QA-104` — Auth session expiry mid-session
Actions: 1) Leave the app signed in past token expiry (or force-expire if testable) 2) Perform any Supabase-backed action.
Expected UI: silent token refresh, no visible interruption; if the refresh token itself is also expired/invalid, a clean sign-out prompt, not a crash.
PASS: as described.

### `QA-105` — Malformed/oversized manual input
Actions: 1) Attempt to save a transaction with a zero amount 2) Attempt an extremely long note/merchant text.
Expected UI: zero-amount rejected with a clear message; long text saved/truncated without a crash or UI overflow.
PASS: as described.

### `QA-106` — Device clock set far in the future
Actions: 1) Set device clock 1 year ahead 2) Trigger an SMS capture with a body containing an SMS-internal date.
Expected DB: the implausible SMS-body timestamp is rejected by the server's sanity bounds, falling back to `received_at` rather than storing a nonsensical date.
Cleanup: reset device clock.
PASS: as described.

### `QA-107` — Network interruption mid-write
Actions: 1) Start a transaction save 2) Toggle airplane mode on immediately during the network call, then off shortly after.
Expected UI: either a clean typed error, or (if the request actually completed server-side before the toggle) a successful save with no duplicate on any automatic/manual retry.
PASS: no duplicate row, no silent data loss, no crash.

---

## 19. Rollback verification

### `QA-108` — Flag rollback (instant mitigation lever)
Preconditions: any per-user override from §16 still active.
Actions: 1) Remove the override 2) Relaunch.
Expected UI: app falls back cleanly to Drift-primary behavior for that entity, no crash, no data loss (mirrored data still present).
PASS: as described (this is the same check as `QA-093`, repeated here explicitly as the "rollback" framing for release-validation sign-off).

### `QA-109` — Migration rollback dry-run understanding (documentation check, not a live action)
Actions: 1) For the most recent migration applied to this project, open its matching `supabase/rollback/NNNN_*.sql` file and read it 2) Confirm it exists and states clearly what, if anything, is irrecoverable.
Expected: a rollback file exists for every migration; none are silently missing.
PASS: rollback file present and clear.
FAIL indicators: a migration with no matching rollback file — flag this as a release-blocking documentation gap per [01_GLOBAL_RULES.md](01_GLOBAL_RULES.md) Rule 8, do not attempt to write one yourself as part of QA sign-off; escalate to engineering.

### `QA-110` — Cache-dirty repair path (rollback-adjacent)
This is the same scenario as `QA-083`/`QA-086` — re-confirm here specifically framed as "does the system recover cleanly from a flag rollback performed while the local cache was mid-repair." Actions: 1) Force a dirty cache state 2) Immediately disable the override (rollback) before a repair has run 3) Relaunch.
Expected: no crash; either the dirty flag correctly still gates a stale Drift read with a typed error, or (if repair completed first) a clean fallback.
PASS: no silent stale-data serving in either ordering.

---

## 20. Final cleanup & sign-off

### `QA-111` — Remove all QA overrides and confirm global state unchanged
Actions:
```sql
delete from feature_flag_overrides where user_id = '<qa_user_id>';
select key, is_active, rollout_percent from feature_flags
where key like '%supabase_primary%' or key in ('capture_direct_supabase_write','ledger_dual_write');
```
Expected: zero override rows remain for the QA user; every global flag still shows OFF/0%, exactly as confirmed in `QA-000`.
PASS: matches `QA-000`'s baseline exactly.
FAIL indicators: any global flag state has drifted from OFF — this must be resolved before the release can be considered validated, regardless of how well every other test passed.

### `QA-112` — Remove all QA capture-pipeline rows
Actions:
```sql
delete from processed_captures where install_id_hash = '<qa_install_id_hash>';
delete from capture_fingerprints where install_id_hash = '<qa_install_id_hash>';
delete from capture_rate_limits where install_id_hash = '<qa_install_id_hash>';
delete from capture_devices where install_id_hash = '<qa_install_id_hash>';
```
Expected: zero rows remain for this QA install anywhere in the four capture tables.
PASS: confirmed via a follow-up `SELECT` returning zero rows for each.

### `QA-113` — Confirm real user data untouched throughout
Actions:
```sql
select count(*) from user_accounts where user_id != '<qa_user_id>';
select count(*) from user_transactions where user_id != '<qa_user_id>';
```
Expected: counts identical to whatever they were before this playbook began (record the baseline count before starting the playbook, compare here).
PASS: unchanged.
FAIL indicators: any change in real-user row counts — treat as a serious incident, not a QA note; follow [25_DISASTER_RECOVERY.md](25_DISASTER_RECOVERY.md) if confirmed.

### `QA-114` — Final sign-off
Actions: 1) Compile every FAIL from this run into a single list with test IDs 2) Confirm every gate in [10_TEST_STRATEGY.md](10_TEST_STRATEGY.md) §3 relevant to the changes under validation has also been run and passed.
PASS (release-ready): zero unresolved FAILs, all automated gates green, `QA-111`/`QA-112`/`QA-113` all confirmed clean.
FAIL (not release-ready): any open FAIL from this playbook, or any gate not actually run/confirmed — do not mark a release validated on the assumption that gates "probably" passed elsewhere; confirm explicitly per [20_FINAL_REPORT_TEMPLATE.md](20_FINAL_REPORT_TEMPLATE.md).
