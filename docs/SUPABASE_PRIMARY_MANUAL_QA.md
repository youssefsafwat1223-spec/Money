# Supabase-Primary Manual QA

Status: required before any global cutover. All production flags stay OFF.

## Safety setup

- Use two dedicated users: `QA-A` and `QA-B`. Never use a real customer.
- Enable only per-user overrides. Start with one feature at a time.
- Capture row counts before and after each test.
- Never paste service-role credentials into the app or device logs.
- After every group, remove overrides and delete only rows marked by the test's
  `QA-` name/client request identifier.
- Required OFF global flags: every `*_supabase_primary`,
  `dashboard_supabase_summary`, `capture_direct_supabase_write`, legacy ledger
  sync flags, planning sync flags, and `smart_inbox_pull_sync`.

## QA-01 Authentication and onboarding

- Preconditions: fresh install; no session; all overrides absent.
- Actions: finish the welcome flow, sign in as QA-A, force-close, reopen.
- Data: display name `QA-A Primary`.
- Expected UI: onboarding completes once; authenticated home opens; no empty
  local-only financial row is created before authentication.
- Supabase: authenticated session belongs to QA-A; no QA-B row is readable.
- Drift/cache: settings/onboarding state may be local; financial counts remain
  unchanged.
- Logs/notification: no token, SMS, or user identifier is printed.
- Cleanup: sign out only after the remaining QA-A tests.
- PASS: restart restores the session and repository calls authenticate.
- FAIL: financial UI accepts a permanent guest write or exposes another user.

## QA-02 Accounts

- Preconditions: QA-A override `accounts_supabase_primary=true`.
- Actions: create, rename, make default, then delete one account.
- Data: `QA-EGP`, EGP, bank, initial balance 1000.
- Expected UI: each action completes after server success; network failure shows
  an error and preserves entered form values for retry.
- Supabase: `user_accounts` increases exactly once; stable `local_id`; default
  change is atomic; delete sets `deleted_at`.
- Drift/cache: mirror appears only after success and contains `server_id`; no
  planning outbox row is created.
- Logs/notification: safe repository error code only; no account values logged.
- Cleanup: tombstone the QA account after dependent tests.
- PASS: server UUID is used by subsequent direct entities.
- FAIL: local row reports success before server response or two rows appear.

## QA-03 Transactions

- Preconditions: QA-A account and overrides for accounts + transactions primary.
- Actions: create expense, update amount/category, retry the same submission,
  then delete.
- Data: EGP 123.45, merchant `QA Market`, category shopping, fixed request ID.
- Expected UI: one transaction, updated values, then hidden after delete.
- Supabase: one `user_transactions` row; correct `server_account_id`,
  `direction=debit`, `transaction_type=expense`; retry does not overwrite or
  duplicate; delete sets `deleted_at`.
- Drift/cache: post-success mirror has `server_id`; no ledger outbox row.
- Logs/notification: no raw message or request identifier printed.
- Cleanup: keep tombstone until summary exclusion is verified.
- PASS: exactly one canonical row and correct tombstone.
- FAIL: unrestricted upsert changes an existing retry or local-only success.

## QA-04 Dashboard

- Preconditions: QA-A transaction/account primary plus
  `dashboard_supabase_summary=true` per-user; one income, expense, refund, and
  transfer in current month.
- Actions: open dashboard; switch month/account; refresh.
- Data: income 1000, expense 200, refund 20, transfer 300 EGP.
- Expected UI: expense 200, income 1000, refund shown per product copy,
  transfer excluded from income/expense; selected-account scope is preserved.
- Supabase: summary RPCs read only QA-A and use a half-open UTC range.
- Drift/cache: dashboard result does not come from local aggregate while flag ON.
- Logs/notification: no financial values logged.
- Cleanup: delete QA rows after reports test.
- PASS: server totals match SQL exactly.
- FAIL: transfer counted, month boundary duplicated, or QA-B affects totals.

## QA-05 Reports and pagination

- Preconditions: QA-A direct transactions; generated QA set of 1,201 expenses.
- Actions: open reports, merchant/category/card views, change date range.
- Data: deterministic dates across two months; one last4 `1938`.
- Expected UI: all 1,201 rows contribute; category and merchant totals match;
  no implicit 1,000-row truncation.
- Supabase: queries paginate 500 rows with stable `occurred_at,id` ordering and
  fixed upper creation boundary.
- Drift/cache: not used as report authority while primary flag ON.
- Logs/notification: no card number beyond allowed UI last4.
- Cleanup: bulk-delete only QA-tagged rows.
- PASS: exact count/totals and no duplicates across pages.
- FAIL: 1,000 cap, drifting upper bound, or wrong last4 filter.

## QA-06 Budgets

- Preconditions: accounts, transactions, and budgets primary overrides ON.
- Actions: create monthly all-expenses budget, edit, inspect progress, delete.
- Data: EGP 500 linked to QA-EGP.
- Expected UI: local form remains responsive; result appears after server success;
  progress uses direct transaction totals.
- Supabase: one `user_budgets`, owner account UUID, category key, tombstone on
  delete.
- Drift/cache: mirror contains server ID only after success.
- Logs/notification: no amount in error logs.
- Cleanup: tombstone QA budget.
- PASS: unresolved local account is rejected, never guessed.
- FAIL: a local account ID is sent as a server FK.

## QA-07 Goals and contributions

- Preconditions: accounts + goals primary ON.
- Actions: create goal; add the same contribution request twice; delete goal.
- Data: target 5000, contribution 250 EGP, fixed contribution request ID.
- Expected UI: saved amount increases once to 250.
- Supabase: one goal and one contribution; atomic RPC locks owner row; retry
  returns the same contribution; tombstone/archival follows repository behavior.
- Drift/cache: goal and contribution mirror once; no double count.
- Logs/notification: no request ID or balance logged.
- Cleanup: tombstone QA goal.
- PASS: `saved_amount=250` after duplicate retry.
- FAIL: 500, orphan child, or cross-user parent accepted.

## QA-08 Subscriptions and bill payments

- Preconditions: subscriptions + transactions primary ON.
- Actions: create installment, record payment twice with same request, delete
  payment, then cancel subscription.
- Data: 12 installments, EGP 300 each, installment index 1.
- Expected UI: paid count becomes 1 once, then returns to 0 after deletion.
- Supabase: one subscription/payment; payment RPC is idempotent; transaction FK
  is same-user or null; rows are tombstoned, not hard deleted.
- Drift/cache: authoritative `paid_count` and payment are mirrored post-success.
- Logs/notification: no bill note or financial payload logged.
- Cleanup: tombstone QA subscription.
- PASS: counters match active child rows.
- FAIL: duplicate payment increments count or delete hard-removes history.

## QA-09 Plans and transaction links

- Preconditions: plans + accounts + transactions primary ON.
- Actions: create dated plan; link same transaction twice; inspect spent; unlink.
- Data: `QA Trip`, EGP 2000, one EGP 123.45 expense.
- Expected UI: one linked transaction and spent 123.45, then zero after unlink if
  it is outside automatic matching rules.
- Supabase: one plan/link; stable pair request ID; ownership triggers reject QA-B
  transaction; unlink sets `deleted_at`.
- Drift/cache: server plan/link IDs mirror when parent mappings exist.
- Logs/notification: no transaction details logged.
- Cleanup: tombstone QA plan.
- PASS: repeated link creates no duplicate.
- FAIL: broken transaction reference or cross-user link.

## QA-10 Smart Inbox

- Preconditions: `smart_inbox_supabase_primary=true` for QA-A.
- Actions: insert a QA `needs_review` item through approved backend/admin test,
  open Transactions, dismiss it, resume app.
- Data: title `QA Review`, no raw SMS.
- Expected UI: banner/card appears once; dismiss survives resume.
- Supabase: status changes to `dismissed`; owner-only row.
- Drift/cache: known item mirrors; unknown future type is skipped safely.
- Logs/notification: no metadata body logged.
- Cleanup: tombstone QA item.
- PASS: dismissed item does not resurrect.
- FAIL: widget queries Supabase directly or unknown type crashes UI.

## QA-11 iOS Shortcut direct capture

- Preconditions: real iPhone, notifications allowed, cloud ON, QA-A linked
  capture device, transactions + `capture_direct_supabase_write` overrides ON.
- Actions: run `Process Bank SMS` once with a supported sanitized test message.
- Data: QNB debit EGP 1, last4 1938, current date/time.
- Expected UI: no app opening; later transaction appears from Supabase.
- Supabase: one `processed_captures` relay row and exactly one canonical
  `user_transactions` row with `source_payload_id` and `source=ios_shortcut`.
- Drift/cache: no independent local transaction; app mirrors canonical server ID.
- Logs/notification: payload/SMS absent from logs; parsed Qirsh notification.
- Cleanup: open app to ack relay; tombstone QA transaction.
- PASS: canonical row exists before app opens.
- FAIL: relay missing, two canonical rows, or app forced open.

## QA-12 APNs

- Preconditions: QA-11, app killed, valid production token for TestFlight.
- Actions: trigger Shortcut; tap notification.
- Data: one supported purchase and one needs-review message.
- Expected UI: APNs arrives; transaction notification opens its server ID;
  needs-review opens Smart Inbox/pending fallback.
- Supabase: relay remains until app sync; `apns_push_sent_at` set on success;
  push failure never rolls back processing.
- Drift/cache: tap syncs/mirrors then acks relay.
- Logs/notification: one Qirsh result notification; App Intent does not add local
  duplicate when backend reports `pushSent=true`.
- Cleanup: ack rows and remove QA token/device if test device is retired.
- PASS: route resolves after sync.
- FAIL: duplicate Qirsh notifications or missing canonical ID route.

## QA-13 Feature flag rollback

- Preconditions: QA-A has one primary override ON and clean cache health.
- Actions: use feature; set override false; background/resume app.
- Data: one QA entity existing on both server/cache.
- Expected UI: resume invalidates providers and switches to Drift without app
  reinstall; selected account resets when account routing changes.
- Supabase: global flag remains OFF.
- Drift/cache: only allow rollback when cache health is clean.
- Logs/notification: safe transition message in debug only.
- Cleanup: remove override.
- PASS: override false wins immediately on resume.
- FAIL: stale provider still displays server route until restart.

## QA-14 Network failure

- Preconditions: one direct primary override ON.
- Actions: open create form, enter data, enable airplane mode, submit, disable
  airplane mode, retry with same request ID.
- Data: `QA Offline Retry`, EGP 77.
- Expected UI: first submit errors and does not claim success; input remains;
  retry succeeds once.
- Supabase: zero rows after failure, one after retry.
- Drift/cache: zero permanent row after failure; mirror only after retry.
- Logs/notification: safe retryable code, no payload.
- Cleanup: tombstone QA row.
- PASS: no local-only financial row and no duplicate retry.
- FAIL: optimistic success or changed idempotency ID.

## QA-15 Multi-user RLS

- Preconditions: QA-A and QA-B sessions on separate clients.
- Actions: for every user-owned table, attempt A read/update/delete of B row and
  attempt A child referencing B parent; repeat unauthenticated.
- Data: one clearly named QA parent/child per table.
- Expected UI: access denied/not found without leaking existence.
- Supabase: owner reads succeed; cross-user and anon operations return no row or
  401/403; service role remains server-only.
- Drift/cache: no foreign user row imported.
- Logs/notification: no row contents in error logs.
- Cleanup: each owner removes only its QA rows.
- PASS: all isolation attempts blocked.
- FAIL: any cross-user row or parent reference succeeds.

## QA-16 Backfill

- Preconditions: QA-A has legacy Drift rows; direct flags OFF; server snapshot
  and local encrypted backup available.
- Actions: accounts backfill, transactions backfill, planning backfill in the
  documented order; interrupt once and rerun.
- Data: active + tombstoned parent, child, unresolved account, and duplicate.
- Expected UI: unchanged because flags stay OFF during backfill.
- Supabase: inserts by stable local/request IDs; rerun matches without overwrite;
  unresolved parents are reported, never guessed.
- Drift/cache: original rows remain; server IDs populated only for matched rows.
- Logs/notification: aggregate counts and safe error types only.
- Cleanup: delete only QA server rows after exporting reconciliation report.
- PASS: resumable, idempotent, created+matched+failed reconcile with local total.
- FAIL: remote edit overwritten, orphan inserted, or local row deleted.

## QA-17 Cache dirty and repair

- Preconditions: primary flag ON; induce a test-only local mirror failure after
  a successful QA server write.
- Actions: submit; inspect `financial_cache_health`; run repair; retry rollback.
- Data: one `QA Cache Repair` entity.
- Expected UI: authoritative server success is returned; no duplicate retry.
- Supabase: exactly one row.
- Drift/cache: entity marked dirty; repair rehydrates from Supabase, verifies,
  then clears dirty; kill-switch rollback is blocked while dirty.
- Logs/notification: error runtime type only.
- Cleanup: tombstone QA row and clear test health state through repair.
- PASS: server success survives mirror failure safely.
- FAIL: user sees failure and creates a second server row.

## QA-18 Month rollover

- Preconditions: summary flags for QA-A and rows on both sides of month boundary.
- Actions: inspect previous/current month and cumulative account balance.
- Data: expense at `23:59:59.999` local last day and at `00:00:00.000` next day;
  include Egypt offset and one DST timezone test account.
- Expected UI: each row appears in one month only; new month starts at its own
  totals; cumulative account balance does not reset.
- Supabase: half-open UTC ranges; old rows remain.
- Drift/cache: no monthly deletion/reset.
- Logs/notification: none expected.
- Cleanup: tombstone QA rows.
- PASS: exact boundary and balance behavior.
- FAIL: row counted twice/missing or account balance resets.

## Final release gate

Do not enable production flags until all 18 cases pass, two-user RLS passes for
every new table/RPC, TestFlight APNs and Shortcut tests pass, reconciliation is
clean, privacy disclosures are updated, and rollback has been rehearsed.
