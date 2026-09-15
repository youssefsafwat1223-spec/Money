# V1 QA Evidence

Actual runtime and test evidence. A line without evidence is not a PASS.

Measured 2026-09-15, re-measured 2026-09-16 against HEAD.

## 1. Static and unit/widget

| Gate | Result |
|---|---|
| `flutter analyze` | **0 issues** (was 25 at the start of this effort) |
| `flutter test` | **3,923 pass · 2 skipped · 0 fail** (2026-09-16) |
| iOS simulator build | **PASS** — `Runner.app` builds, installs, launches |
| iOS **release** build | **PASS** — `flutter build ios --release --no-codesign` → `Runner.app` (60.2 MB); the Share Extension compiles and the widened redaction classes are present in the shipped binary |
| `deno test supabase/functions` | **348 pass · 2 ignored · 0 fail** (2026-09-16) |
| Swift sanitizer parity | **18/18** — `app/tool/verify_swift_sanitizer.sh`, which lifts `sanitize()` out of the shipped source verbatim so the code under test is the code that ships |

### 1.1 What the 2026-09-16 additions actually cover

| Suite | What it would catch |
|---|---|
| `supabase/functions/_shared/sms_redaction_test.ts` (9) | An IBAN, OTP or Arabic-Indic identifier reaching the model; an amount destroyed by over-redaction; a `/g` regex made stateful in a fail-closed gate |
| `supabase/functions/register-device/handler_test.ts` (6) | A rotated relay secret inheriting a user link. **Confirmed by reverting the fix** — the rotation test fails, the other five still pass |
| `app/test/architecture/report_ads_guards_test.dart` (+1) | An `AdRequest` made personalized, which would make the shipped privacy manifest untrue. **Confirmed by flipping the flag** |
| `app/test/engine/sms_sanitizer_test.dart` (+8) | The same corpus as the Deno and Swift suites, so the three implementations cannot drift apart silently |

## 2. Exhaustive route sweep — iOS Simulator (iPhone 17, iOS 26.5)

Populated state (demo seed: 3 accounts, 2 cards, 59 transactions, 3 budgets,
2 goals, 6 coupons).

**30 routes reached. 139 control verdicts.**

| Verdict | Count |
|---|---|
| PASS | 139 across both passes |
| NOT APPLICABLE | 60 |
| DEAD-TAP | 19 |
| NOT-REACHED | 11 |
| FAIL | 2 |
| UNSAFE TO TEST | 1 (sign-out — deliberate, it ends the session mid-sweep) |

### The sweep had to be sliced, and why that matters

Run whole, the sweep reported **20 failures**. Nineteen of them were false. One
control — `حفظ الميزانية` — navigated while the Navigator was mid-frame, raised
`!_debugLocked`, and left the element tree corrupt; every route visited
afterwards then failed on `_elements.contains(element)` and was reported as a
product failure it had nothing to do with.

Sliced one route per process, the same suite reports **2** failures. The
difference is entirely measurement, not the product. This is recorded because a
green-looking 20-failure report and a real 2-failure report are indistinguishable
unless someone reads the cascade.

### The 2 remaining failures

| Control | Cause | Disposition |
|---|---|---|
| `/goals/new` → `أنشئ الهدف` | Navigator re-entrancy (`!_debugLocked`) — the control navigates away as it saves | **Harness limitation, not a defect.** The same operation is proven end to end by the CRUD matrix: `goal/C`, `goal/R`, `goal/U`, `goal/D` all PASS. |
| `ROUTE /design` | ErrorWidget on arrival in a debug build | **Not V1-blocking.** `/design` is registered only under `kDebugMode` (`app_router.dart:307`) and does not exist in a release build — the profile-build sweep correctly rendered "Page Not Found". Recorded as a debug-surface defect. |

Three controls in total are unmeasurable by this harness — `حفظ الميزانية`,
`أنشئ الهدف`, `لصق رسالة يدويًا`. All three navigate as they act, and all three
are covered by other evidence.

## 3. Deep CRUD matrix — physical device

**15 cells, zero failing.**

| Entity | C | R | U | D |
|---|---|---|---|---|
| Budget | PASS (exactly 1 row) | PASS (rendered) | PASS (`amount_minor` 77700→88800) | PASS |
| Goal | PASS | PASS | PASS (`saved_amount_minor` 0→10000, 1 contribution) | PASS |
| Transaction | — (covered by journey D) | PASS | PASS (`category_id` changed) | **UNSAFE TO TEST** |
| Account | PASS (form opens, writes nothing) | PASS (4 listed) | — | — |

`transaction/D` is deliberately not exercised: every transaction row on the
device belongs to the user, and the delete path also enqueues a ledger mutation
that restoring the row would not reverse.

## 4. Triage probe — every unresolved sweep verdict

26 verdicts. All 12 prior NOT-REACHED results resolved: 11 PASS, 1 genuine
DEAD-TAP. Also proved the six `maybePop` close buttons work when the route is
entered by `push` (the sweep enters by `go`, which leaves nothing to pop), the
`/reports` tab bar moves `controller.index`, the budget period segments become
active, app-lock toggles, and clipboard paste lands.

## 5. What is NOT proven

| Claim | Status |
|---|---|
| Physical-device APNs delivery | **BLOCKED — hardware only** |
| Cloud-OFF verified on the wire | **UNVERIFIED** — enforcement is code-read, never observed as network behaviour |
| Exact financial push/pull | **BLOCKED BY PRODUCT CONTRACT** — all three transport capabilities are `unknown`; push/pull is dark by design |
| Full English UI | **NO** — 11% localized; see V1_LOCALIZATION_MATRIX.md |
| Release archive validated | **NOT YET RUN** |
| Guidance screenshots from final UI | **NOT PRODUCED** |
