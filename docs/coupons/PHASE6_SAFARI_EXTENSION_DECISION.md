# Phase 6 — Safari Web Extension: **DEFER**

**Decision date:** 2026-09-01
**Status:** Not built. Phase 6 is CLOSED on this decision, not left open.

Phase 6 was always a go/no-go gate rather than an approved feature. Two
independent reviewers assessed it against the current repository and both said
do not build it now — one as a NO-GO, one as a DEFER. The difference is only
whether the door is closed permanently or conditionally, so this records the
conditional form, with the conditions named precisely enough to be checked.

---

## Why not

**The value over Share-to-Qirsh is one tap, minus the part that made the pattern
famous.** Share-to-Qirsh already gives: merchant page → share sheet → Qirsh →
that merchant's offers. An extension removes an app switch. It would NOT
auto-apply codes at checkout — that needs per-merchant form injection and a
maintenance treadmill this project has no team for, in an Arabic e-commerce
landscape the existing coupon extensions cover poorly anyway. And on iOS the
proactive half is throttled by Apple's own funnel: Settings → Safari →
Extensions, then a per-site permission prompt worded to alarm. Most users never
arrive.

**It spends the product's core asset on its least aligned feature.** Qirsh's
privacy posture is provable by absence: it holds no permission to read Messages,
so it cannot. A browsing-observer extension replaces "we cannot see it" with
"we can see it and promise not to look" — indistinguishable, to a user or a
journalist, from every coupon extension that does look. For a finance app whose
differentiator is precisely this, that is a bad trade even with a clean
on-device implementation.

**Apple review risk concentrates badly.** Guideline 4.4 forbids extensions that
exist for marketing or advertising, and an extension whose purpose is surfacing
commission-bearing merchant promotions has a straightforward rejection argument
against it. 4.4.2 pushes toward minimal host permissions while a growing merchant
catalog pushes the other way. The app is already in finance-app territory and is
simultaneously awaiting a Google Play restricted-permission decision on
`RECEIVE_SMS`, argued on the basis that Qirsh is a narrow, privacy-preserving SMS
money tool. Opening a second policy-sensitive surface mid-review is
self-inflicted.

**No affiliate network is contracted, and networks are the ones who decide.**
Browser-extension attribution is the most heavily regulated topic in affiliate
terms — commonly prohibited outright, or requiring the extension to be registered
as a separate property, with cookie-stuffing and last-click rules enforced by
clawback and account termination. Designing attribution mechanics against
imagined rules risks rearchitecting later, and in the worst case jeopardises the
whole account including in-app links. Building the surface before reading the
clause is backwards.

**The cost is the highest of anything on the table.** `verify_ios_packaging.sh`
asserts exactly `ShareBankMessage.appex` and fails on count mismatch by design;
`ios_input_sha.sh` hashes a fixed input set that has never covered a
WebExtension artifact class. A second `.appex` means a new target, a third App
ID, a new provisioning profile, App Group assignment, changes to both packaging
scripts and their CI contract tests, and a permanently enlarged review surface —
all behind an Apple portal that currently needs a 2FA code from an unavailable
client, with no physical device for QA.

---

## What was done instead

Both reviewers independently identified the same real gap, which was verified
against source and fixed in the same cycle:

**The iOS share extension was text-only.** `Info.plist` declared
`NSExtensionActivationSupportsText` alone and `ShareViewController` loaded only
`public.plain-text`. Safari shares a page as `public.url`, so Qirsh never
appeared in the share sheet for a shop link — the Share-to-Qirsh journey this
decision compares against had **no iOS entry point at all**.

Fixed inside the existing packaging contract, with no new extension:

- `NSExtensionActivationSupportsWebURLWithMaxCount = 1` added alongside text.
- `ShareViewController` routes by item type, **URLs first** — Safari attaches
  the page title as plain text next to the URL, so the text branch would have
  fed a page title to the SMS parser.
- A new `SharedOfferIntentStore`, separate from `SharedCaptureStore`, in two
  byte-identical copies per the existing convention, added consciously to the
  provenance input set.
- A `drainOfferIntents` channel method on both platforms, reading its own store.

The extension's display name is still "إضافة رسالة بنك", which is now inaccurate
for a URL share. Renaming it is a product decision and is **left open** rather
than decided here.

---

## What would reopen this

All three, together. Any one alone is not enough.

1. **A signed affiliate agreement whose terms explicitly permit a browser
   extension** — read, in writing, not assumed.
2. **Apple portal access restored**, with the third App ID and App Group
   provisioned and a physical device available for Safari QA.
3. **Evidence that merchant-URL sharing is actually used** — instrumented
   Share-to-Qirsh usage showing people reach offers that way, which is what
   would demonstrate demand for making it proactive.

"When we have more time" is not a condition and does not reopen it.
