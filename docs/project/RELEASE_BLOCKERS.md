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

---

## OPEN — blocking PRODUCTION, not blocking further engineering

### RB-4 — the production migration ledger is unknowable · **CRITICAL** · EXTERNAL

**Evidence.** `0072_backend_security_hardening.sql:5` claims "0001-0092 applied
and ledger-verified on production". `0084_purge_user_data_restore.sql:4` says
"SOURCE-ONLY. NOT APPLIED TO ANY PROJECT." 0084 ≤ 0092; both cannot be true.
`supabase migration list --linked` returns **403 — "Your account does not have
the necessary privileges"**.

**Why it blocks.** 0084 is a *data-erasure repair* migration. If it is not
applied, account deletion may not fully erase. Shipping a deletion feature whose
server side may be absent is not defensible, and nothing in this repository can
tell you which it is.

**Owner action.** From the Supabase dashboard for project `rjwphwsefnuotpbtuycf`,
read `supabase_migrations.schema_migrations` and report the highest applied
version. Or grant this account Management API privileges so it can be read
automatically.

**Not blocking.** Any client-side work. Migrations 0093–0098 are known
source-only and their features are all behind OFF flags.

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
| `set_default_account` gates on transport, not consent | MEDIUM | An inconsistency with its sibling services in the same pipeline. Real, worth fixing, not release-stopping. |
| No JVM test source set for Android | LOW | Kotlin is covered by structural assertions over source rather than execution. Weaker, and recorded as such. |
| iOS share extension still named «إضافة رسالة بنك» | LOW | Now inaccurate for a URL share. A product naming decision, deliberately left to the owner. |
| `app/android/key.properties` on disk | LOW | Gitignored, never committed, and now asserted so by the corrected guard. Consider relocating outside the repo anyway. |
