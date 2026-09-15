# V1 Visual Evidence

How the device screenshots are produced, what they prove, and — because two of
the three runs produced pictures that looked fine and were not — what the
harness had to learn to tell the difference.

## 1. How to reproduce

```sh
# iPhone 17 Pro Max — the 6.9" class the App Store listing requires.
xcrun simctl boot BECCE2FE-8921-480C-9896-0ED7560355FB

cd app
QIRSH_SCREENSHOT_DIR=~/.qirsh-qa/screenshots \
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/store_screenshots_test.dart \
  -d BECCE2FE-8921-480C-9896-0ED7560355FB \
  --dart-define-from-file=~/.qirsh-qa/qa_run_defines.json
```

`takeScreenshot` inside a test only *requests* a capture; the bytes arrive in
the driver. `test_driver/integration_test.dart` exists solely to write them, and
every other integration test in this repo still runs under plain `flutter test`.

## 2. What the harness got wrong first

All worth recording, because each produced a full set of plausible PNGs.

**Seeding in a separate run does not survive.** Installing the app replaces its
container, so a device seeded by an earlier `flutter test` invocation arrives at
the `flutter drive` run with an empty database. The first two runs photographed
a listing's worth of empty states. The seeding test is now called from the
screenshot test's own `main()`, so it runs in the same process against the same
database.

**GoRouter's error page is a valid `Scaffold`.** `/transactions` is not a route
— transactions are a tab inside `AppShell` — so `router.go('/transactions')`
served "Page Not Found", and a guard that checked for an `ErrorWidget` and for
the presence of a `Scaffold` passed it. The capture was saved and named
`02-transactions`. Nothing but the text distinguishes that page, so the guard
now looks for it explicitly.

**Then the same mistake, one layer down.** Reaching the tab by
`find.text('العمليات')` matched the dashboard's own section header of that name.
Tapping it did nothing, and the run produced a second copy of the dashboard
filed as `02-transactions` — byte-identical to `01-dashboard`, which is how it
was noticed. Scoping the finder to the bottom nav bar then found *nothing*,
which was the correct answer and the useful one: the nav renders **icons only**
(`// أيقونة بس — الاسم بيفضل في الـ Semantics للقارئ الصوتي`), so the label is
never a `Text` widget at all. The tabs are reached by semantics label, with
`ensureSemantics()` on, since that tree is not built otherwise.

Because a tab switch does **not** change the route — every tab lives at `/` —
the only honest signal that a tap did something is that the rendered text
changed. The test compares it and refuses to save a capture when it has not.

The pattern in all four: the harness found *a* thing that looked right and
believed it. Every guard added is a way of stating what "right" actually means,
and two of these were caught only because the output files came out
byte-identical in size.

## 3. What the captures show

| File | Surface | Charter relevance |
|---|---|---|
| `00-coach-marks` | The dashboard tour, first card | **RC-5 Layer A** — fires by itself on first dashboard visit |
| `01-dashboard` | Home with seeded data | — |
| `02-transactions` | Transactions tab | — |
| `03-analytics` | Analytics tab | — |
| `04-reports` | Reports | **RC-3** — the annual presets live here |
| `05-budgets`, `06-goals`, `07-accounts`, `08-cards`, `09-subscriptions` | Planning surfaces | — |
| `10-help` | "كيف تستخدم قِرش" | **RC-5 Layer B** — persistent and re-openable |
| `11-settings`, `12-privacy` | Settings and privacy | — |

## 4. What they do NOT prove

- **Nothing about Apple review.** These are captures, not an approval.
- **Nothing in English.** The app is Arabic-first and the listing should declare
  Arabic only; see `V1_LOCALIZATION_MATRIX.md`. A screenshot set claiming
  English would be untrue before it was unhelpful.
- **Nothing on hardware.** Simulator only. Device-matrix items stay BLOCKED.
- **Nothing about the data.** The figures are the demo seed, not real money, and
  the seed exists so the screens are not empty — not to assert any number.

## 5. Store use

The files are written outside the repository (`~/.qirsh-qa/screenshots`) on
purpose: they are build output, they are large, and they are regenerated from
source by one command. Nothing here is a substitute for the owner-side steps —
metadata, description, age rating and privacy labels are declared in App Store
Connect, not in this repo.
