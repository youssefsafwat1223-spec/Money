# Banner placements — device QA, 2026-09-19

Simulator: iPhone 17 Pro Max, debug build, Google TEST ad units.
Harness: `app/integration_test/ads_placement_qa_test.dart`.
Baseline: `7ff3585b` — the five placements plus the four blocker fixes.

**Nothing was activated.** `_defaults` is untouched and every flag is still
`false`. The walk turned the placements on by writing rows into this device's
own `remote_feature_flags` table and deleted them again. No file under `ios/`,
`android/`, `codemagic.yaml` or any `ADMOB_*` input was touched.

## What was real, and what was not

The whole app ran — `MoneyApp`, the real router, the real `AppShell` with its
floating navigation bar. The **flag gate was the real one** this time; an
earlier run wrote the flag rows and then also overrode the provider that reads
them, so the writes did nothing. The build-config gate, the visual gates, the
Reports suppression and cooldown, and the throttle and its retry were all the
shipping code.

Two gates were stubbed, and only two: `bannerEntitlementProvider` and
`bannerConsentProvider`. Both reach off-device and a debug build without
`SUPABASE_URL` has nothing to reach. **Neither is verified here.** They need a
signed-in pass with QA credentials, which is an owner action.

Every case started from a cleared throttle and cleared suppression. Without
that, an earlier run read `h0` in three combinations out of four and it meant
nothing.

---

## RESULT: NOT A PASS

The run recorded 30/30 PASS. **That label was wrong**, because the pass
criterion was "an ad loaded with a height > 0" rather than "an ad is visible".
The criterion has since been tightened; the findings below are what the
geometry in that run actually shows.

### 1. No ad creative appeared in ANY capture — unresolved · BLOCKS SIGN-OFF

Every screenshot shows the "Advertisement" label over an **empty box**. That
includes Goals, where the slot sits fully on screen with room to spare.

This is not simply a capture artifact: an early run of an earlier harness DID
capture a test creative on Achievements, so the pipeline can record a platform
view, and the native glass navigation bar — also a platform view — renders in
these very captures. The current run waits for a non-zero height and then for
1.2 s of REAL time before shooting, so the earlier timing explanation no longer
covers it.

Two possibilities remain and the evidence does not separate them: the ad is not
rendering in the real app, or `takeScreenshot` is not compositing this
particular platform view. **Resolving this needs a human looking at the
simulator.** Until then no visual claim about these placements is supported.

### 2. The Dashboard banner lands entirely below the fold · REAL

`top=844 below=-75` in all four combinations, on a 956pt screen. The slot's
bottom edge is 75pt past the bottom of the display.

The cause is sequencing, not layout. The banner is the last direct child of the
list, so it materialises only when the reader reaches the end — and the ad
arrives *after* that, growing the list by 187pt while the scroll offset stays at
the old maximum. Everything the ad added, including its own lower half and the
112pt navigation clearance, is below the fold until the reader scrolls again.

An ad that is requested, loaded and never seen is the viewability problem in its
purest form.

### 3. Achievements has the same defect · REAL

`top=864 below=-95` in three of four combinations. Same cause.

### 4. Goals is the near miss · REAL

`top=744 below=25`. The ad is on screen, but the 120pt navigation clearance
underneath it is not — the floating bar overlaps the foot of the slot.

### 5. Reports and Subscriptions sit 10pt from the tab pills · NEEDS A DECISION

`tabGap=10` on both, in all four combinations. Ten logical points between an
advertisement and a tab control is the adjacency Google's discouraged-placements
guidance names, and the label plus the 800 ms tap shield do not settle it.

The captures show a second problem at the same spot: the reserved slot is a
hard-edged rectangle that cuts the blue gradient between the header card and the
tab bar. Whatever is decided about the gap, that block needs design review.

### 6. One case recorded PASS without running · FIXED IN THE HARNESS

`goals · scrolled far away and back` reported PASS with `loaded=null` — no ad
ever loaded, so the case never exercised anything. It now records BLOCKED.

---

## What the run did establish

- **The flag gate works end to end.** Writing the rows turned the placements on;
  deleting them turned them off.
- **A pushed route suppresses the banner** — verified on device, not inferred.
- **The export ad journey suppresses it** (`during=true`) — blocker 1, on device.
- **The cooldown ends without a rebuild** (`hiddenDuring=true returned=187`) —
  blocker 3, on device.
- **A resize drops the stale creative** on both a header and a list placement —
  blocker 2, on device.
- **One banner instance across tab switches** on Reports (3 tabs) and
  Subscriptions (2 tabs), tapped by label so RTL is not a coin toss.
- **The empty state carries no ad.**

## Still not covered

Entitlement and consent on device; real hardware rotation (the walk resizes the
test surface, which is not the same thing); and any visual claim at all, pending
finding 1.

---

## Disposition

**Not sufficient to activate any flag.** Findings 1–4 are blockers: one
unresolved rendering question and three placements whose ad is partly or wholly
unseeable at the moment it loads.
