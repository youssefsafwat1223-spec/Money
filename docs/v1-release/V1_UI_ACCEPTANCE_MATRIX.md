# V1 UI Acceptance Matrix

Reconciles the UI Atlas and the HTML prototype against current HEAD.

Sources:
* `/Users/luciq/Documents/QirshWorktrees/app-onboarding/docs/ui-atlas/` — 20 documents, measured 2026-09-10/11 on `feat/onboarding-visual`
* `/Users/luciq/Documents/QirshWorktrees/app-onboarding/design/qirsh_full_app_ui.html` — 382 KB prototype

**Correction first.** An earlier readiness entry marked the atlas SUPERSEDED on
judgment, without opening it. That was wrong twice over: the atlas is accurate
against current HEAD, and it already contained the surface enumeration that the
same report listed as NOT PROVEN.

---

## 1. Surface counts — atlas vs current HEAD

Measured by the same method on both trees.

| Metric | Atlas (2026-09-10) | HEAD (2026-09-16) | Delta | Explanation |
|---|---|---|---|---|
| `showModalBottomSheet` call-sites | 45 | **45** | 0 | exact |
| `showDialog` call-sites | 27 | **28** | +1 | the RC-5 coach-mark `AlertDialog` |
| `SnackBar(` sites | 77 | **79** | +2 | RC-5 Help replay toast, and one other V1 addition |
| `GoRoute(` declarations | 35 | **36** | +1 | `/help` (RC-5 Layer B) |

Every delta is accounted for by V1 work in this effort. **The atlas is not
stale for surface inventory.**

| Metric | Atlas | HEAD | Delta | Explanation |
|---|---|---|---|---|
| `app_ar.arb` keys | 369 | **338** | −31 | different branch. The atlas measured `feat/onboarding-visual`, which carries onboarding-redesign keys `main` does not |
| `app_en.arb` keys | 321 | **338** | +17 | `main` brought English to **exact parity**; the atlas branch was 48 keys behind |

The ARB divergence is a branch difference, not drift. On `main` the two
languages now hold identical key sets, enforced by `test/l10n/arb_parity_test.dart`.

## 2. The V1 surface denominator

The honest denominator for "every screen, sheet, dialog, menu, form":

| Class | Count | Source |
|---|---|---|
| Routes | 36 | router parse, HEAD |
| Shell tabs | 5 | `_BottomNavBar._items` |
| Bottom-sheet call-sites | 45 | HEAD |
| Dialog call-sites | 28 | HEAD |
| SnackBars | 79 | HEAD |
| Screen files (`*_screen.dart`) | 40 | atlas glob |
| Widget classes | 399 (154 public) | atlas |

Thirteen device captures cover the routes, not the sheets and dialogs. That gap
is stated rather than papered over.

## 3. HTML prototype fidelity — ALREADY CLOSED

`HTML_CONTENT_FIDELITY_REPORT.md` records a completed before/after pass:

| | Before | After |
|---|---|---|
| COMPLETE | 21 | **47** |
| PARTIAL | 23 | **0** |
| WRONG IMPLEMENTATION | 3 | **0** |

Verification output from that pass:

```
QIRSH_DATA_CHECK() → { valid: true, errors: [] }
QIRSH_COVERAGE()   → contracts 16/16 complete · missing: 0 · partial: 0
                     frames 129 (111 ACTIVE) · overlays 17 · dialogs 10 · components 24
```

**Direction of the fix matters.** Every gap was prototype-side — the evidence
column cites what the Flutter already did correctly. `CARDS-CARDDETAILS-DEFAULT`
"rendered a different screen" describes the HTML, and the citation is
`card_details_screen.dart:41-190` showing the Flutter was right. The prototype
was corrected to match the app, so **no Flutter content-fidelity defect is
outstanding from that pass.**

## 4. Surfaces the atlas discovered that no route reaches

From `UI_SURFACE_GAP_REPORT.md` — 74 candidates inspected, 30 false positives,
and these real ones. They matter here because they are exactly the sheets,
states and dialogs a route-only walk cannot reach.

| Type | Count | Examples |
|---|---|---|
| Full-screen conditional roots | 3 | `_DatabaseRecoveryView` (corrupt DB), `AppLockGate`, `AppBootLoader` restore overlay |
| Missing states | 8 | Smart Inbox banner, suspected-duplicates banner, import preview, import result, planning-repair gate (budgets + goals), startup error |
| Missing overlays | 12 | Smart Inbox sheet, suspected-duplicates sheet, card-attach, paste batch results, plan detail, plan link, settings categories/category-form/picker/profile-text/info/quiet-hours |
| Missing dialogs | 2 | `showDatePicker` (10 call sites), `showTimePicker` (2) |
| Internal tab frames | 3 | reports tab bar, budget period segments, transactions/bills toggle |
| Flag-gated | 2 | `QirshAdBanner` (`enable_banner_ads`, default off) |

**These are documentation gaps that the atlas closed, not Flutter defects.**
Each row cites a live root class and a trigger.

## 5. Acceptance status

| Fidelity dimension | Status | Evidence |
|---|---|---|
| Content fidelity | **ACCEPTED** | §3 — 47/47 COMPLETE after the prototype pass; no Flutter-side defect outstanding |
| Visual fidelity | **ACCEPTED for V1 scope** | 13 device captures at 1320×2868 reviewed against the shipped design; contrast measured on real tokens |
| Behavior fidelity | **PARTIAL** | Route-level behaviour exercised by the sweep (232 verdicts) and CRUD matrix (15 cells). Sheet/dialog behaviour is inventoried here but not individually driven |
| State fidelity | **PARTIAL** | Empty and populated captured. The 8 states in §4 — loading, error, repair-gate, import preview/result — are inventoried, not driven |

## 6. What this matrix does NOT claim

* That every one of the 45 sheets and 28 dialogs has been opened on a device.
  They have not. §2 gives the denominator so the shortfall is visible.
* That the atlas branch and `main` are the same tree. They are not; §1 states
  the ARB divergence and its cause.
* That the prototype is a specification. It is a fixture corrected to match the
  app, which is the opposite direction of authority.
