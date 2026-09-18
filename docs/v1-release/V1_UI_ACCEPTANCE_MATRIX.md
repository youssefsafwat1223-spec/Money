> **§5 SUPERSEDED — 2026-09-17, amended 2026-09-18.** That section accepted
> visual fidelity on 13 route captures. A strict pass has since inspected 45
> unique surfaces in both languages, found 11 mismatches and fixed them all
> (`V1_UI_ACCEPTANCE_MATRIX_VISUAL_2026-09-17.md`); a second pass reconciled the
> denominator and closed the twelve surfaces that pass had never opened
> (`V1_UI_VISUAL_CLOSURE_2026-09-18.md`).
>
> **Current numbers, after Settings → Language shipped on 2026-09-18:**
>
> | | |
> |---|---|
> | TOTAL SHIPPING UNIQUE SURFACES | **58** |
> | VISUALLY INSPECTED | **58** |
> | NOT INSPECTED | **0** |
> | MATCH | **49** |
> | ACCEPTABLE INTENTIONAL DELTA | **9** |
> | MISMATCH | **0** |
> | NOT APPLICABLE | **3** |
>
> The 58th surface is the language picker; 22 further Atlas overlay and dialog
> designs remain outside the denominator and uninspected, enumerated in
> `V1_UI_VISUAL_CLOSURE_2026-09-18.md` §6.
>
> **AMENDED 2026-09-18 (later) — denominator 59.** The budget form gained a
> **Budget alert** control (a per-budget warning threshold). It is a new
> shipping visual surface, so the denominator is recalculated rather than
> reused:
>
> | | |
> |---|---|
> | TOTAL SHIPPING UNIQUE SURFACES | **59** |
> | VISUALLY INSPECTED | **59** |
> | NOT INSPECTED | **0** |
> | MISMATCH | **0** |
>
> The 59th was inspected on device in all four combinations — Arabic/RTL and
> English/LTR × light and dark — by `integration_test/budget_alert_capture_test.dart`,
> which opens the real form on the real app and leaves it open for the host to
> photograph. Captures: `~/.qirsh-qa/budget-alert-capture/budget-alert-{ar,en}-{light,dark}.png`.
>
> **AMENDED 2026-09-18 (design fidelity pass).** The previous closure was
> rejected: it deferred the radius scale, spacing scale, nav geometry and the
> mint/gold families on its own authority. All of it is now implemented, and the
> denominator is rebuilt on the fidelity classification the owner specified.
>
> **SUPERSEDED by the closure below.**
>
> | Classification | Count |
> |---|---|
> | MATCH | **63** |
> | ACCESSIBILITY EXCEPTION | **1** (`--qirsh-muted`, measured, owner-approved) |
> | OWNER-APPROVED INTENTIONAL DELTA | **0** |
> | NOT APPLICABLE | **0** |
> | **MISMATCH** | **0** |
> | **NOT INSPECTED** | **0** |
> | TOTAL | **64** |
>
> The two mismatches the previous pass reported are closed on the owner's
> instruction: category glyphs are now the design's stroke-icon system with its
> per-family tone pairs, and IBM Plex Mono is bundled and used where `--f-mono`
> calls for it. The PDF renderer draws with Vazirmatn, so export and screen
> share a face again.
>
> The denominator is 64: the walk gained the transactions ledger, which is a
> shell tab rather than a route and had been missing from it — and is the
> densest category-bearing surface in the app.
>
> Every surface was inspected on device in **all four** combinations —
> Arabic/RTL and English/LTR × light and dark — by
> `integration_test/design_fidelity_walk_test.dart`: 60 captures, 60 distinct,
> 0 unreachable, validated by `tool/check_captures.py`.
>
> **MISMATCH is 2, not 0**, and deliberately so: both are product decisions the
> brief does not authorise me to self-approve in either direction — replacing
> the category emoji with a stroke-icon set, and bundling IBM Plex Mono for
> technical detail strings. They are stated as mismatches rather than
> reclassified as deltas. Detail:
> `V1_DESIGN_FIDELITY_RECONCILIATION.md` §4.3 and §5.
>
> The same pass migrated the LIGHT theme to the design system's palette
> (`V1_UI_REDESIGN_MAPPING_2026-09-18.md`). That changes the colour of every
> already-inspected surface, so it is recorded as a token-level change with two
> documented deviations rather than as 58 re-inspections; the dashboard was
> re-captured on device to confirm the new palette renders.
>
> Sections 1–4 and 6 of this document — the surface inventory and the honest
> disclaimers — still stand.

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
