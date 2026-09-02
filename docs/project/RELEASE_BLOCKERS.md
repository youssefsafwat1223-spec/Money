# Qirsh — release blockers

**As of 2026-09-02.** A blocker is something that makes a release *indefensible*,
not merely imperfect. Everything else is in `MASTER_ROADMAP.md` as debt.

Policy: **zero unresolved RELEASE BLOCKER and zero unresolved CRITICAL** before
claiming Release Candidate or higher.

---

## RESOLVED on 2026-09-02

### RB-1 — Android automatic SMS capture was unreachable ✅ FIXED

The build declared `RECEIVE_SMS` and registered a live `SMS_RECEIVED` receiver
for a feature no user could switch on. Google Play requires a declared
restricted permission to enable core functionality a reviewer can exercise; the
privacy policy was already live saying the app captures bank SMS; and Settings
told users it does not.

Fixed by wiring the Settings toggle, correcting the copy, and adding a
reachability guard. See `CURRENT_STATE.md`.

### RB-2 — Four canonical CI gates failing ✅ FIXED

`tools/ci_gates.sh` is this repository's CI authority and it reported
`mandatory gates failed: 4`. All four are now honest: the arch guard's schema
pin (stale at 31 through four approved bumps), `app/CLAUDE.md` (said 33), 19
node skips with no stated reason, and a signing guard that scanned the
filesystem while claiming to check what was committed.

### RB-3 — a false privacy claim in a Play submission draft ✅ FIXED

`data_safety_draft.md` stated the egress inventory had "0 open" findings. It has
three. That document is destined for a regulatory submission.

### RB-4 — the production migration ledger was unknowable · ✅ **CLOSED 2026-09-02**

**Resolved by owner verification.** A read-only query against
`supabase_migrations.schema_migrations` on the production project
(`rjwphwsefnuotpbtuycf`) confirmed the ledger is **continuous through 0092**,
with 0084–0092 each explicitly present.

The `SOURCE-ONLY / NOT APPLIED` headers on 0084, 0085 and 0086 were stale: they
named an earlier production project that is no longer the deployment target.
Corrected in place; deployment state now lives in one file,
`MIGRATION_LEDGER.md`.

**What this closes:** the worst open unknown in the product — `0084` is a
data-erasure repair, so "possibly unapplied" meant "account deletion may not
fully erase and we cannot tell". It is applied. Deletion completeness is
server-side verified.

**What it does not close:** 0093–0098 remain source-only and must not be
assumed deployed. Every feature depending on them is behind an OFF flag, so
nothing is broken by their absence.

---

## OPEN — blocking PRODUCTION, not blocking further engineering

### RB-5 — no physical device has ever been used · **RELEASE BLOCKER** · DEVICE

**Evidence.** No Android device has ever been attached to this machine; iOS
needs Apple portal access requiring an unavailable 2FA code. No simulator or
emulator run has been performed either.

**Why it blocks.** Every one of these is unverifiable without hardware and is
load-bearing: SMS receipt with the app closed, multipart SMS reassembly, process
death and restart, notification delivery, APNs, background execution, the iOS
share extension and App Group handoff, permission grant/revoke behaviour, banner
rendering under a modal sheet (`AdWidget` is a platform view and platform views
have bled over Flutter modals in this app before), and the whole v34→v35
migration on a real populated database.

**Owner action.** Connect an Android device with USB debugging and run
`Qirsh Production/18_Android_SMS_Capture/device_qa_plan.md` and
`docs/MANUAL_BANNER_QA_CHECKLIST.md`. iOS needs the portal unblocked first.

### RB-6 — Google Play restricted-permission approval · **RELEASE BLOCKER** · EXTERNAL APPROVAL

`RECEIVE_SMS` requires an approved permissions declaration under the SMS-based
money management exception. The draft is ready and **not submitted**; the Data
Safety form likewise.

**Before submitting**, reconcile three documents that currently do not agree:
the declaration draft says no SMS text reaches an AI provider; the Data Safety
draft records an optional sanitized-text path that the backend retains; the live
privacy policy describes an optional cloud/AI path. All three must say the same
thing, and the true statement is the third one — the path exists, is
consent-gated and is off by default.

---

## NOT blockers — recorded debt

| Item | Severity | Why it does not block |
|---|---|---|
| Proof-Carrying engine unwired | CLEANUP | Zero production callers, so zero runtime effect. Dart AOT strips unreferenced code. Both reviewers: ship dormant, recorded. Activation is an integration change, not a flag flip. |
| Affiliate click gateway unwired | CLEANUP | Coupons work; the CTA opens the plain merchant URL. No network is contracted, so wiring a gated egress path now adds accidental-activation risk for no benefit. |
| `SupabaseEngagementRecorder` unwired | LOW | Nothing reaches the network. Recorded as an OPEN egress finding so the consent obligation is visible before a caller appears. |
| `record_metric` has no client consent gate | MEDIUM | Server-side owner-bound, allowlisted, rate-limited; carries a key and a coarse dimension, never user data. Tracked, not hidden. |
| ~~`set_default_account` gates on transport, not consent~~ | ✅ FIXED | Closed 2026-09-02. One consent gate at the `StartupSyncReconcileService` entry now covers every backfill it drives, defaults to DENY, and refusal is its own outcome. |
| No JVM test source set for Android | LOW | Kotlin is covered by structural assertions over source rather than execution. Weaker, and recorded as such. |
| iOS share extension still named «إضافة رسالة بنك» | LOW | Now inaccurate for a URL share. A product naming decision, deliberately left to the owner. |
| `app/android/key.properties` on disk | LOW | Gitignored, never committed, and now asserted so by the corrected guard. Consider relocating outside the repo anyway. |
