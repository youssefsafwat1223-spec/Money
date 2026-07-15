# Mali — Consolidated Manual iPhone QA Checklist (Batches 1-4)

Every test below requires a real iPhone (or the iOS Simulator where explicitly noted as sufficient) —
this session's environment has no interactive display and cannot drive real device UI, so none of
these have been executed yet. Perform in the order listed within each group where a dependency exists;
groups themselves can be done in any order. Use a dedicated QA Supabase account, never a real user's.

Scope note: Admin-panel authorization (finding #1) is a Next.js web app, not a mobile feature — verify
it separately via a browser, not as part of this iPhone checklist. Android `FLAG_SECURE` (#22) requires
an Android device and is likewise out of scope for an *iPhone* checklist — note it here only as a
reminder that it still needs its own Android-device pass.

---

## 1. Authentication / Session

### 1.1 — Sign-in from `sessionExpired`
- **Action:** On a device with a stale/invalid cached session (e.g. revoke the session server-side via
  Admin API first, or reuse a previously-invalidated refresh token), launch the app.
- **Expected UI:** App shows the sign-in screen ("سجّل دخولك"), not the dashboard, and not a stuck
  spinner.
- **Expected notification:** None.
- **Expected Supabase change:** None until the user actually signs in again.
- **Expected local cache state:** No financial data flashes before the redirect; onboarding-completion
  flags are preserved (user isn't sent through onboarding again, only re-auth).
- **PASS/FAIL:** PASS if sign-in screen appears within a few seconds with no dashboard flash; FAIL if
  the dashboard renders with stale/broken data, or the app hangs.

### 1.2 — Session revoked while backgrounded, then resumed
- **Action:** Sign in normally, background the app, revoke the session server-side (Admin API or
  dashboard), then bring the app back to foreground.
- **Expected UI:** App detects the invalid session on resume and redirects to sign-in, without
  requiring a force-quit.
- **Expected notification:** None.
- **Expected Supabase change:** None.
- **Expected local cache state:** Financial data providers are invalidated, not left showing
  now-inaccessible cached data.
- **PASS/FAIL:** PASS if redirected to sign-in within a few seconds of resuming; FAIL if the app
  continues showing the dashboard as if still signed in, or crashes.

### 1.3 — Sign-out with stale-data-flash check
- **Action:** Sign in, load the dashboard fully, sign out, immediately sign in as a **different** QA
  user.
- **Expected UI:** No frame of the previous user's balances/transactions is visible during the
  transition; the new user's (empty or their own) data appears.
- **Expected notification:** None.
- **Expected Supabase change:** None beyond normal auth state.
- **Expected local cache state:** All financial providers invalidated on sign-out; nothing from user A
  persists into user B's session view.
- **PASS/FAIL:** PASS if zero visible flash of user A's data; FAIL if even briefly visible.

---

## 2. Accounts and Financial Writes

### 2.1 — Account creation double-tap
- **Action:** Open "add account," fill the form, rapidly double-tap "save" (or tap once on a throttled
  connection).
- **Expected UI:** Button visibly disables / shows a spinner after the first tap; no way to trigger a
  second submission.
- **Expected notification:** None.
- **Expected Supabase change:** Exactly one new row in `user_accounts`.
- **Expected local cache state:** Exactly one account appears in the accounts list.
- **PASS/FAIL:** PASS if exactly one account is created; FAIL if two are created or the app hangs.

### 2.2 — Final-account deletion rejection
- **Action:** As a QA user with exactly one active account, attempt to delete it.
- **Expected UI:** A clear error explaining the last account can't be deleted, not a silent failure or
  crash.
- **Expected notification:** None.
- **Expected Supabase change:** No change — `delete_user_account_safely` rejects with `23514`.
- **Expected local cache state:** The account remains present and unchanged.
- **PASS/FAIL:** PASS if deletion is cleanly rejected with a visible message; FAIL if it silently
  succeeds, crashes, or hangs.

### 2.3 — Bill creation + immediate payment, slow network
- **Action:** Throttle network (Settings → Developer, or Xcode Network Link Conditioner), create a new
  bill/subscription with an immediate payment recorded.
- **Expected UI:** Save button/dialog visibly shows a busy/spinner state for the duration of the save;
  does not close until the request resolves.
- **Expected notification:** None (this is a manual create, not a capture).
- **Expected Supabase change:** Exactly one row in `user_subscriptions`, exactly one row in
  `user_bill_payments`, correct `paid_count` if the bill type is `installment`.
- **Expected local cache state:** Bill and payment mirrored into local cache exactly once.
- **PASS/FAIL:** PASS if exactly one subscription/payment pair results even with a forced retry; FAIL
  on duplicates or a UI that appears to hang with no feedback.

### 2.4 — Goal contribution double-tap
- **Action:** Open a goal's contribution sheet, enter an amount, rapidly double-tap "save."
- **Expected UI:** Button disables and shows a spinner after the first tap.
- **Expected notification:** None.
- **Expected Supabase change:** Exactly one row in `user_goal_contributions`; `user_goals.saved_amount`
  incremented exactly once.
- **Expected local cache state:** Goal's saved amount matches the server exactly.
- **PASS/FAIL:** PASS if exactly one contribution is recorded; FAIL on double-counting.

### 2.5 — Bill due-date and manual-paid-amount validation
- **Action:** In the bill form, attempt to (a) pick a past due date directly if the picker somehow
  allows it, (b) enter `0` in the manual-paid-amount field, (c) enter a negative manual-paid-amount.
- **Expected UI:** Each invalid input is rejected with a clear inline/snackbar message before any save
  attempt reaches the network.
- **Expected notification:** None.
- **Expected Supabase change:** None for any rejected attempt.
- **Expected local cache state:** Unchanged.
- **PASS/FAIL:** PASS if all three invalid inputs are blocked client-side; FAIL if any reaches the
  server or is silently accepted.

---

## 3. iOS Shortcut and Capture Durability

### 3.1 — Extension killed mid-network-request
- **Action:** Trigger the Shortcuts automation with a real (or simulated) bank SMS, then immediately
  force-quit the Shortcuts app/extension via the App Switcher, or enable Airplane Mode the instant the
  automation fires. Wait, then disable Airplane Mode / relaunch Mali.
- **Expected UI:** No crash; on next Mali launch, the transaction eventually appears.
- **Expected notification:** Exactly one notification once the retry succeeds (not zero, not two).
- **Expected Supabase change:** Exactly one row in `processed_captures` and `user_transactions` for
  this message, using the same `payloadId` on the eventual successful retry.
  - Fastest way to check `payloadId` reuse: query
  ```sql
  select payload_id, created_at from processed_captures
  where install_id_hash = '<this device's hash>' order by created_at desc limit 5;
  ```
- **Expected local cache state:** Transaction appears exactly once in the transactions list.
- **PASS/FAIL:** PASS if the transaction appears exactly once, however delayed; FAIL if it never
  appears, or appears twice.

### 3.2 — Rapid-fire SMS burst
- **Action:** Trigger the Shortcuts automation for 4-5 different bank SMS in quick succession (within a
  few seconds of each other) — e.g. several tap-to-pay purchases back to back, or manually re-running
  the automation on several saved test messages.
- **Expected UI:** No crash, no dropped message.
- **Expected notification:** One notification per genuinely distinct message.
- **Expected Supabase change:** One `processed_captures` row and one `user_transactions` row per
  distinct message — none lost, none duplicated.
- **Expected local cache state:** All transactions present exactly once each.
- **PASS/FAIL:** PASS if all messages are captured exactly once each; FAIL if any is lost or
  duplicated.

---

## 4. APNs / Local Notifications

### 4.1 — Notification permission denied
- **Action:** In iOS Settings, deny notification permission for Mali (or deny during onboarding).
  Trigger a real SMS capture.
- **Expected UI:** No crash; the transaction still imports and appears in the app on next open.
- **Expected notification:** None (expected — permission denied).
- **Expected Supabase change:** `processed_captures.apns_push_error` populated (a real error, not
  silently null), `user_transactions` row still created normally.
- **Expected local cache state:** Transaction appears normally despite no push.
- **PASS/FAIL:** PASS if the transaction still imports correctly with no crash; FAIL if capture itself
  fails or the app crashes.

### 4.2 — APNs registration failure surfaced in Settings
- **Action:** Force an APNs registration failure if possible (e.g. airplane mode during initial
  registration, or a known-bad test configuration), then open Settings.
- **Expected UI:** The capture-health tile shows "تعذّر تفعيل إشعارات رصد البنك" with the underlying
  error message, not silently absent.
- **Expected notification:** N/A (this is a Settings-screen check).
- **Expected Supabase change:** None.
- **Expected local cache state:** N/A.
- **PASS/FAIL:** PASS if the failure is visible in Settings; FAIL if nothing is shown despite a real
  registration failure.

### 4.3 — Rich vs. fallback notification content
- **Action:** Trigger a capture that parses successfully (rich content expected) and separately one
  that fails to parse on both backend and device (fallback expected — e.g. airplane mode + a garbled
  test message).
- **Expected UI:** N/A (notification-focused test).
- **Expected notification:** Rich case shows merchant/amount; fallback case shows the honest
  "لم نتمكن من تحليل..." wording (not the old "تم استلام رسالة..." wording — confirm the old string
  never appears).
- **Expected Supabase change:** `processed_captures.status` = `processed` for the rich case, `rejected`
  for the fallback case.
- **Expected local cache state:** Rich case creates a transaction; fallback case does not.
- **PASS/FAIL:** PASS if wording matches exactly as described for each case; FAIL if the old vague
  wording appears anywhere, or if content is swapped between the two cases.

---

## 5. Duplicate Prevention

### 5.1 — Same SMS forwarded twice quickly
- **Action:** Trigger the same real SMS through the Shortcuts automation twice within a few seconds
  (simulating a flaky automation double-fire).
- **Expected UI:** No crash.
- **Expected notification:** Exactly one "new transaction" notification (the second is silently treated
  as duplicate, or shows a distinct "duplicate" indicator if the app surfaces one — not a second
  identical notification).
- **Expected Supabase change:** Exactly one row in `user_transactions`, exactly one row in
  `capture_fingerprints` for this fingerprint bucket.
- **Expected local cache state:** Exactly one transaction.
- **PASS/FAIL:** PASS if exactly one transaction results; FAIL on any duplicate.

### 5.2 — Bill-payment retry after a forced failure
- **Action:** Start recording a bill payment, force a failure mid-request (airplane mode toggle),
  restore connectivity, retry via the same UI.
- **Expected UI:** Clear error on failure, successful retry without needing to re-enter data.
- **Expected notification:** None.
- **Expected Supabase change:** Exactly one row in `user_bill_payments` despite the retry.
- **Expected local cache state:** Exactly one payment recorded.
- **PASS/FAIL:** PASS if exactly one payment results; FAIL on duplicate or permanent failure.

---

## 6. Capture Health

### 6.1 — Stale capture nudge
- **Action:** Disable the Shortcuts automation (or don't trigger any capture for a simulated period —
  may require backdating a test transaction's timestamp via direct DB update for practicality), then
  open Settings.
- **Expected UI:** Capture-health tile shows "لم نستقبل رسائل بنكية منذ فترة" with a "تحقق" action once
  the gap exceeds 7 days.
- **Expected notification:** N/A.
- **Expected Supabase change:** None (read-only check).
- **Expected local cache state:** N/A.
- **PASS/FAIL:** PASS if the nudge appears once the threshold is exceeded and not before; FAIL if it
  never appears, or appears prematurely.

---

## 7. App-Switcher Privacy (iOS)

### 7.1 — App-switcher snapshot blanking
- **Action:** Sign in, view the dashboard with real balances visible, background the app (swipe up to
  App Switcher without fully closing).
- **Expected UI:** The App Switcher thumbnail shows a blank/branded ("قرش") screen, not the real
  dashboard content. Returning to the app immediately shows real content again with no visible delay.
- **Expected notification:** N/A.
- **Expected Supabase change:** None.
- **Expected local cache state:** N/A.
- **PASS/FAIL:** PASS if the thumbnail never shows real financial data; FAIL if real data is visible in
  the App Switcher even briefly.
- **Note:** iOS has no API to block an in-app screenshot taken while actively using the app — this test
  is specifically about the App Switcher snapshot, which is the achievable ceiling on this platform.

---

## 8. Offline / Timeout / Retry

### 8.1 — Account creation while offline
- **Action:** Enable Airplane Mode, attempt to create an account.
- **Expected UI:** Clear, friendly error shown; form fields remain populated for retry.
- **Expected notification:** None.
- **Expected Supabase change:** None while offline.
- **Expected local cache state:** No account created.
- **PASS/FAIL:** PASS if a clear error is shown and the form is retryable once online; FAIL on a silent
  failure, crash, or lost form input.

### 8.2 — Bill payment while offline, then retry online
- Covered by 5.2 above — re-verify specifically the "offline" trigger path if not already covered.

---

## 9. Onboarding

### 9.1 — "Start fresh" goes through full setup
- **Action:** Sign in as a brand-new QA user, when offered the restore prompt choose "start fresh."
- **Expected UI:** Full sequence: country/currency selection → account setup → capture (Shortcuts)
  setup guide → dashboard. No step skipped.
- **Expected notification:** None.
- **Expected Supabase change:** A default account created matching the chosen country/currency.
- **Expected local cache state:** Onboarding-completion flag set only after the full sequence.
- **PASS/FAIL:** PASS if all steps appear in order; FAIL if any step (especially the capture guide) is
  skipped.

### 9.2 — "Restore from backup" skips to capture guide only
- **Action:** Sign in as a QA user with an existing backup, choose "restore from backup."
- **Expected UI:** After the restore completes, the flow goes directly to the capture (Shortcuts) setup
  guide — NOT back through country/currency/account setup (already present in the restored data) —
  then to the dashboard.
- **Expected notification:** None.
- **Expected Supabase change:** None beyond the restore itself.
- **Expected local cache state:** Restored data intact; onboarding-completion flag set after the
  capture guide step.
- **PASS/FAIL:** PASS if country/currency/account setup is correctly skipped but the capture guide
  still appears; FAIL if either skipped when it shouldn't be, or shown when it shouldn't be.

---

## 10. User Switching and Device Unlinking

### 10.1 — User A signs out, User B signs in on the same device
- **Action:** Sign in as QA user A, capture at least one real SMS, sign out **before** confirming it
  was synced/acknowledged if possible (or immediately after). Sign in as QA user B on the same
  physical device.
- **Expected UI:** User B never sees any transaction, account, or notification belonging to A.
- **Expected notification:** Any notification that arrives after B signs in must reference only B's
  data.
- **Expected Supabase change:** `capture_devices.user_id` updated to B; any `processed_captures` row
  created while linked to A is stamped `claimed_user_id = A` and must never be returned to B's
  `sync-captures` call.
- **Expected local cache state:** B's local Drift cache contains zero trace of A's transactions.
- **PASS/FAIL:** PASS if zero cross-user leakage is observed in the UI or in a direct DB check of what
  `sync-captures` would return to B; FAIL if any of A's data becomes visible to or claimed by B.

---

## Summary

10 groups, 20 individual tests. None have been executed — all require a real iPhone (Simulator
sufficient only for 3.2, 4.3, 9.1, 9.2, 10.1; the others need real notification permission/App
Switcher/network-toggle behavior that the Simulator does not faithfully reproduce). Perform after
code review, before commit, per the standing plan.
