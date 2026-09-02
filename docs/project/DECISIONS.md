# Qirsh — decision record

Decisions that shaped the product, with the reasoning that produced them. A
decision belongs here when reversing it would cost real work or real trust.

Reversed decisions stay, marked REVOKED, because the fact that a position was
held and abandoned is what stops it being re-proposed.

---

## D-1 · Android automatic SMS capture is a required core feature · 2026-08-31

**Owner decision.** Revokes the earlier "Play-safe, share-only" position.
Recorded in `Qirsh Production/18_Android_SMS_Capture/README.md`.

Consequences that are now load-bearing: `RECEIVE_SMS` is declared (and only
that — no `READ_SMS`, so the receiver reads broadcast intents and never touches
`content://sms`); privacy policy §8 describing capture is **live**; publication
is gated on Play approval.

> **REVOKED:** "Android SMS capture is intentionally disabled for MVP"
> (`docs/ANDROID_SMS_CAPTURE_DECISION.md`, pre-2026-08-31). That document
> asserted the manifest declared no SMS permission and no receiver. Both became
> false and it was never revised; it has now been rewritten. A reviewer
> re-proposed the revoked position on 2026-09-02 and withdrew it on seeing D-1.

## D-2 · A granted permission is not consent — the two-key lock

`RECEIVE_SMS` granted **and** `CaptureSettings.autoCaptureEnabled == true`.
The opt-in defaults false, is set only by explicit user action after the
prominent disclosure, and is reset on identity change so one user's consent is
never inherited by the next. `SmsCaptureReceiver.onReceive` returns before
touching the intent unless the opt-in is true.

The UI renders from the platform snapshot, never a cached boolean: a permission
revoked outside the app must not leave a switch reading ON.

## D-3 · Disclosure ordering is structural, not conventional

`AndroidSmsCaptureService.requestAndEnable` takes the disclosure as a callback
and has no code path reaching the system dialog without it returning true. Play
treats a permission dialog shown before disclosure as a violation even when the
user then grants it, so the ordering cannot be left to whoever calls the method.

## D-4 · Forward-only database recovery

Drift is additive and forward-only. A v34 binary cannot open a v35 database.
Recovery is a feature flag, the kill switch, a hotfix or a forward migration —
**never shipping an older build**. Every bump forces a repository-wide sweep of
version pins.

## D-5 · UMP is the sole advertising-consent authority

No Qirsh-owned advertising-consent boolean exists, and an architecture test
asserts no `adConsentState` symbol appears anywhere in `lib/`. Separate from
`cloudProcessingEnabled`, which governs product analytics only.

## D-6 · No ATT prompt; every ad request is non-personalized

`AdRequest(nonPersonalizedAds: true)` plus the legacy `npa` extra, on both
formats. No `NSUserTrackingUsageDescription`. If personalized advertising is
ever wanted it is a separately approved configuration covering the ATT prompt,
the plist key and UMP IDFA messaging together.

## D-7 · Ad-free entitlement is three-state, and uncertainty means no ad

`verifiedActive` → no ad. `verifiedInactive` → eligible. `unknownOrStale` — any
timeout, unreachable server, malformed response, signed-out session or stale
cache → **no ad**. Never "not entitled".

A reviewer argued this loses revenue from signed-out users. The router disproved
it: unauthenticated users never reach the screens where ads appear.

## D-8 · One banner placement, chosen over density

Transactions list only. Coupons excluded outright rather than labelled — it is
an owned affiliate marketplace and a third-party banner competes with the offers
it exists to sell. Both reviewers independently.

## D-9 · No ad telemetry that implies an impression opportunity

There is no `*_suppressed_*` event and there must never be one. An event meaning
"this user was eligible for an ad but we withheld it" is exactly the signal the
ad-free design promises never to emit.

## D-10 · Nothing publishes itself

`ingestOffers` has no code path producing `published`. Making affiliate offer
publication automatic would take a schema change, not a config flag.

## D-11 · Savings abstain rather than invent

No structured value, no currency, a different currency, a basket below the
minimum, a pending conversion, an approved conversion of unknown size — all
produce *nothing*, not zero. Zero reads as "you saved nothing", which is a
different and false statement.

## D-12 · Exact reviewed merchant aliases, never fuzzy matching

A false category chip is user-correctable; "you shop at X constantly", derived
from someone's bank messages when they do not, is a trust breach in a finance
app. Recall is an alias-coverage problem solved by adding data.

## D-13 · Proof-Carrying engine ships dormant

Implemented, tested, **zero production callers**. Both reviewers: do not
activate pre-release, do not delete. Activation is an integration change (wire a
call site, ship it disabled, then use the activation pack) — **not a flag flip**,
which the activation pack incorrectly implied.

## D-14 · The affiliate click gateway stays unwired until a network exists

Coupons work today: the CTA opens the validated HTTPS merchant URL untracked.
Wiring a remotely-gated egress path before a contract exists adds
accidental-activation risk for zero benefit.

## D-15 · Phase 6 Safari extension — DEFER

Three conditions must hold together to reopen: a signed affiliate agreement
explicitly permitting a browser extension, Apple portal access restored with a
device for QA, and instrumented evidence that merchant-URL sharing is actually
used. "When we have more time" is not a condition.

## D-16 · A gate that is always red is not a gate

Applied twice on 2026-09-02. The arch guard pinned the schema at 31 and failed
on four separately approved bumps; the signing guard was named "no key material
is committed" but scanned the filesystem, so it failed on every machine capable
of building a signed release. Both were corrected to assert their real
invariant — the signing guard is now *stronger*, asking git what is tracked
anywhere in the repo rather than what sits in one directory.

The inverse also holds: a skip with no stated reason is indistinguishable from a
silently disabled test, so 19 of them were made to state why rather than being
whitelisted.

## D-17 · Documentation that contradicts source is a defect, not a nit

Four documents claimed things the code disproved: the SMS decision doc said the
manifest had no permission; the activation pack described activating code with
no call site; the release-readiness doc recorded Drift v31; and a **Play Data
Safety draft** claimed zero open egress findings when there are three. The last
one would have gone into a regulatory submission.
