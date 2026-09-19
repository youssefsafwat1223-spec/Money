# Banner placements — device QA, 2026-09-19

Simulator: iPhone 17 Pro Max, debug build, Google TEST ad units.
Harness: `app/integration_test/ads_placement_qa_test.dart`.
Implementation under test: `b5112f25` (five placements) + `91325e3b` (corrected
mechanics test and this walk).

**Nothing was activated.** `_defaults` is untouched, every flag is still `false`,
and no Remote Config was changed. The walk enabled the placements by writing
rows into the simulator's own `remote_feature_flags` table and deleted them
again. No file under `ios/`, `android/`, `codemagic.yaml` or any `ADMOB_*` input
was touched.

---

## What the walk covered

59 captures: ar/en × light/dark across Dashboard, Goals, Subscriptions, Reports
and Achievements, at the top of each screen and at its foot; tab switching on
Subscriptions and Reports; a landscape pass; and a push/pop route cycle.

## Geometry readings

`h<n>` = painted with that height · `h0` = mounted, no ad · `OFFSTAGE` = mounted
but not painted · `NOT-IN-TREE` = not built.

| Surface | Reading | Verdict |
|---|---|---|
| `dashboard-top` | `NOT-IN-TREE` | **correct** — below the fold, sliver laziness holds |
| `dashboard-foot` | `h187 top=657 below=112` | mounts and loads; 112px clearance below |
| `goals-top` | `h0` / `h187 top=744` | mounts |
| `goals-foot` | `h187 top=649 below=120` | 120px clearance below |
| `subscriptions-top` | `h187 top=284 below=672` | header placement, above the tab bar |
| `subscriptions-foot` | `OFFSTAGE` | alive, unpainted — see below |
| `reports-top` | `h187 top=284 below=485` | header placement |
| `reports-foot` | `OFFSTAGE` | same |
| `reports-tab1/tab2` | `OFFSTAGE` | one instance survives tab switches |
| `achievements-foot` | `h187 top=677 below=92` | mounts below the badge grid |
| `route-covered` | `OFFSTAGE` | **suppressed under a pushed route** |
| `route-back` | mounted | returns |

---

## CONFIRMED

**1. Sliver laziness holds on a device.** `dashboard-top :: NOT-IN-TREE` and then
mounted at the foot. The placement rule the implementation rests on is real
outside a widget test.

**2. Route coverage suppresses the banner.** `route-before` mounted →
`route-covered :: OFFSTAGE` → `route-back` mounted. This is the mechanism the
Reports export-flow suppression depends on, now verified on a device.

**3. The header placement is ONE instance and survives tab switches.** Reports
tab1 and tab2 both report the same single banner, no second request.

**4. A header banner scrolled away is OFFSTAGE, not disposed.** This is what
corrected an earlier, wrong withdrawal — see the entry below.

**5. The clearance below the banner is real.** 112px on Dashboard, 120px on
Goals, 92px on Achievements.

---

## A CLAIM THAT WAS WITHDRAWN AND THEN RESTORED

The first walk reported `reports-foot :: ABSENT` and I began recording that the
header placement is disposed on scroll — withdrawing the plan's claim that it
survives. That was wrong.

`find.byType` **skips offstage elements by default**. Both this harness and the
rewritten widget test were asking "is it painted", getting no, and calling it
"unmounted". With `skipOffstage: false` the banner is present and the loader was
never disposed.

The real, now-pinned behaviour: a **list** banner scrolled out is UNMOUNTED and
cannot be re-bought inside the 30-second throttle; a **header** banner is merely
UNPAINTED and comes back intact. The trade is that the header placement holds a
native ad view while off screen and the list placements do not.

---

## NOT CONFIRMED — the ad's appearance

Most captures show the "Advertisement" label above an **empty block** where the
creative should be. That is **not** a confirmed paint defect: the identical
screen and placement (Achievements) rendered the test creative fully in an
earlier run and blank in this one. Same code, same device, different run.

The cause is capture timing — `AdWidget` is a platform view and had not been
composited when `takeScreenshot` fired. The walk settles ~4s before capturing,
which is not always enough.

**Consequence: this run verifies GEOMETRY, not APPEARANCE.** The visual
questions the walk exists for — does the ad crowd the pinned tab bar, how does
it read in RTL — are not answered by these captures.

---

## HARNESS DEFECTS FOUND (each produced a false product finding first)

1. **`tester.drag` was not scrolling the dashboard list.** Reported the banner
   ABSENT in all four combinations. Driving `ScrollPosition` directly mounts it.
2. **Seeded goals had a null `accountId`.** `goalsListProvider` filters by the
   selected/default account, so Goals showed its empty state and the banner was
   correctly suppressed — of data the harness failed to create.
3. **Tab switching was silently skipped everywhere.** The harness looked for
   Material `Tab`; these screens use `AppPillTabBar`.
4. **`find.byType` offstage default** — see above.

## HARNESS GAPS STILL OPEN

- **The throttle poisons every combination after the first.** The 30-second
  per-placement throttle is static and the walk visits the same placement four
  times in one session, so three of four combinations read `h0`. **ar/en ×
  light/dark is therefore NOT covered with a loaded ad.**
- **Arabic tab switching taps the wrong tab.** The tap is computed as a fraction
  from the left, but `AppPillTabBar` uses a direction-aware `Row`.
- **The screens are rendered without `AppShell`**, so `below=` measures distance
  to the screen edge, not clearance from the real floating navigation bar.
- **`setSurfaceSize` is not device rotation.** It resizes Flutter's test
  surface; it cannot exercise native adaptive re-sizing. No loaded ad was
  present in the landscape pass anyway.
- **`bannerEligibilityProvider` is overridden**, which bypasses the flag gates
  and the Reports cooldown as well as entitlement and consent. Writing the local
  flag rows has no effect on this path.
- **Entitlement and consent are unverified on device.** They need a signed-in
  pass with QA credentials, which is an owner action.

---

## Disposition

This is a **partial** pass. Placement geometry, laziness, route suppression, tab
behaviour and clearance are confirmed. Appearance, navigation-bar overlap, real
rotation, the flag gates and the entitlement/consent gates are not.

**Not sufficient to activate any flag.**
