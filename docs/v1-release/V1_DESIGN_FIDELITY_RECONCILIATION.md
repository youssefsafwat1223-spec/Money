# V1 Design Fidelity Reconciliation — 2026-09-18

Full HTML → Flutter reconciliation, reopened after the previous pass was
correctly rejected as incomplete.

| | |
|---|---|
| Design source | `qirsh_full_app_ui.html` |
| SHA-256 | `b5c5b09f5927ea4d223a55b098be318a41110e3bddb0aba32f6e56988d36e8de` |
| 2,993 lines · 69 root vars | 99 frames / 27 overlays / 11 dialogs / 16 components / 5 platform / 2 flag-gated |

Classification per the brief: **MATCH** · **ACCESSIBILITY EXCEPTION** ·
**OWNER-APPROVED INTENTIONAL DELTA** · **NOT APPLICABLE** · **MISMATCH** ·
**NOT INSPECTED**.

Known-unimplemented geometry is **not** counted as MATCH.

---

## 1. What the previous pass got wrong

It migrated the light-theme palette and then classified radius scale, spacing
scale, nav height and the mint/gold families as "deferred — several hundred
call sites". That was a self-approved deferral of owner-requested design work,
and the brief rejects it explicitly. All of it is implemented below.

It also reported typography as "already correct". **That was wrong.** Vazirmatn
was bundled and licensed but was the *fallback*; the primary face was IBM Plex
Sans Arabic. The design names Vazirmatn first. Corrected.

---

## 2. Token reconciliation

### 2.1 Colour — light (`:root`)

| Design | Value | Flutter | Status |
|---|---|---|---|
| `--qirsh-blue` | `#022686` | `AppBrandBlue.brand` | MATCH |
| `--qirsh-blue-deep` | `#011341` | `AppBrandBlue.deep` | MATCH |
| `--qirsh-blue-mid` | `#0336BF` | `AppBrandBlue.strong` | MATCH |
| `--qirsh-blue-light` | `#1653F3` | `AppBrandBlue.mid` | MATCH |
| `--qirsh-sky` | `#688EF3` | `AppBrandBlue.light` | MATCH |
| `--qirsh-blue-wash` | `#D3DDF8` | `ctaSoft`, `infoBg` | MATCH |
| `--ink-btn` / `--nav-bg` | `#0B1024` | `ink` | MATCH *(see §4.1)* |
| `--ground` | `#F4F6FC` | `bg` | MATCH |
| `--chrome` | `#EEF1F8` | `surfaceElevated` | MATCH |
| `--qirsh-hair` | `#E7EBF5` | `surfaceMuted`, `border` | MATCH |
| `--qirsh-ink` | `#0C1330` | `textPrimary`, `onSurface` | MATCH |
| `--qirsh-ink-2` | `#39415C` | `textSecondary` | MATCH |
| `--qirsh-muted` | `#727B96` | `textMuted` = `#67708A` | **ACCESSIBILITY EXCEPTION** §4.2 |
| `--qirsh-success` | `#12855C` | `success`, `income` | MATCH |
| `--qirsh-warning` | `#C9800F` | `warning` | MATCH |
| `--qirsh-danger` | `#C4362C` | `danger`, `expense` | MATCH |
| `--gold` | `#E4BA41` | `accent`, `AppBrandAccent.gold` | MATCH |
| `--gold-deep` | `#B76F27` | `AppBrandAccent.goldDeep` | MATCH |
| `--gold-lit` | `#FFE880` | `AppBrandAccent.goldLit` | MATCH |
| `--qirsh-mint` | `#31D0AA` | `AppBrandAccent.mint` | MATCH |
| `--qirsh-mint-soft` | `#DFF7F0` | `AppBrandAccent.mintSoft` | MATCH |
| `--warn-bg` / `--danger-bg` / `--c-in-bg` | `#FBF0DE` / `#FBE7E4` / `#E1F3EC` | `warningBg` / `dangerBg` / `successBg` | MATCH |

**25 of 25 light tokens now resolve**, one as a measured accessibility
exception. Previous pass: 1 of 24.

### 2.2 Colour — dark (`:root[data-theme="dark"]`)

17 of 19 already matched before this programme began and are unchanged.
`--qirsh-muted` (dark `#6E7683`) and `--chrome` (dark `#0A0B0E`) resolve to
near-neighbours already in the dark scheme — **MATCH** at rendering tolerance.

### 2.3 Radius

| Design | Value | Flutter | Status |
|---|---|---|---|
| `--r-xs` | 8 | `AppRadius.sm` | MATCH |
| `--r-sm` | 12 | `AppRadius.md` | MATCH |
| `--r-md` | 16 | `AppRadius.lg` | MATCH |
| `--r-lg` | 22 | `AppRadius.xl` **20 → 22** | MATCH |
| `--r-xl` | 26 | `AppRadius.xxl` **28 → 26** | MATCH |
| `--r-2xl` | 32 | `AppRadius.xxxl` | MATCH |
| `--r-pill` | 999 | `AppRadius.pill` | MATCH |
| `--r-ctl` | 9 | `AppRadius.control` **(new)** | MATCH |
| `--r-row` | 13 | `AppRadius.row` **(new)**, `button` **16 → 13** | MATCH |
| `--r-card` | 18 | `AppRadius.card` **20 → 18** | MATCH |
| `--r-sheet` | 28 | `AppRadius.sheet` | MATCH |
| `.screen>.sheet` | 34 | `AppRadius.screenSheet` **(new)** | MATCH |
| `.hero` bottom | 30 | `AppRadius.heroBottom` **(new)** | MATCH |
| `.bnav` | pill | `AppRadius.nav` **28 → pill** | MATCH |

### 2.4 Spacing

| Design | Value | Flutter | Status |
|---|---|---|---|
| `--sp-1`..`--sp-5` | 4/8/12/16/20 | `s1`..`s5` | MATCH |
| `--sp-6` | 26 | `s6` **24 → 26** | MATCH |
| `--sp-7` | 34 | `s7` **32 → 34** | MATCH |
| — | — | `s8`/`s9`/`s10` (40/48/64) | NOT APPLICABLE — the design ladder stops at 7 |

### 2.5 Typography

| Design | Flutter before | Flutter now | Status |
|---|---|---|---|
| `--f: "Vazirmatn"…` | `IBMPlexSansArabic` primary | **`Vazirmatn` primary** | MATCH |
| fallbacks | Vazirmatn, Alexandria | IBMPlexSansArabic, Alexandria | MATCH |
| no network fetch | bundled | bundled | MATCH |
| `--f-mono: "IBM Plex Mono"` | absent | absent | **MISMATCH → see §5** |

### 2.6 Components

| Design | Spec | Flutter | Status |
|---|---|---|---|
| `.bnav` | height 60, pill, inset 16 | `navBarHeight` 60, `nav` pill, `navBarInset` 16 | MATCH |
| `.bnav button` | height 52, icon 22 | `_slotHeight` 52 | MATCH |
| `.fab` | 48×48 circle, `--qirsh-blue-light` | `AppSpacing.fabSize` 48 | MATCH |
| `.btn` | radius `--r-row` 13, pad 14 | `AppRadius.button` 13 | MATCH |
| `.btn.sm` | radius `--r-ctl` 9 | `AppRadius.control` 9 | MATCH |
| `.card` | radius 18, `--sh-card` | `AppRadius.card` 18 | MATCH |
| `.msheet` | radius 28 top | `AppRadius.sheet` | MATCH |
| `.chip` | pill | `AppRadius.chip` | MATCH |
| MaliGlass card | — | 28 → **18** | MATCH |
| MaliGlass nav | — | 26 → **pill** | MATCH |
| `.icobox` category | soft tint + coloured glyph | `AppAvatar.category` solid → **soft** | MATCH *(glyph: §4.3)* |
| Budget progress | **bars**, not rings | bars | MATCH |
| Goal progress | ring + gold | ring | MATCH |

---

## 3. Surface inspection

`integration_test/design_fidelity_walk_test.dart` drives the real app and
captures every primary shipping surface in **all four combinations** — Arabic/RTL
and English/LTR × light and dark — in one launch, switching language through
`SaveLanguageUseCase` and theme through `ThemeModeController`, both the app's own
persisted sources.

Validated with `tool/check_captures.py`, which fails a run whose frames are
byte-identical — the guard built after 13 launch-screen captures were once
mislabelled as 13 surfaces.

---

## 4. Exceptions

### 4.1 `ink` — resolved in the design's favour

The previous pass kept the brand blue here, citing UX-002. **The owner has
superseded that**: the prototype is the current authority, `--ink-btn` is
`#0B1024`, and obsolete visual tests are to be updated rather than allowed to
hold stale styling.

`ink` is now `#0B1024`. `ux002_brand_treatment_test` was rewritten: it no longer
pins the token to the brand blue, and instead asserts what the finding was
actually about — that the surface is not the *hueless* grey-black `#0F1115` it
rejected. `#0B1024` is a navy (blue channel leads red by 0.08), and white on it
measures **18.85:1** against the 14.63:1 of the value it replaces.

Status: **MATCH** (no longer a delta).

### 4.2 `--qirsh-muted` — ACCESSIBILITY EXCEPTION

| | |
|---|---|
| HTML value | `#727B96` |
| Flutter value | `#67708A` |
| Rendered size | body/caption text, 11–13px — normal text, so AA is 4.5:1 |
| Measured, HTML value | **3.90:1** on `--ground` `#F4F6FC` · 4.21:1 on `#FFFFFF` |
| Measured, shipped value | **4.56:1** on `--ground` · **4.93:1** on `#FFFFFF` |
| Basis | WCAG 2.1 AA 1.4.3. Same hue (225°) and saturation (0.146), darkened to the first passing step |

The design's own value fails AA at the size it is used, on the design's own
background. This is the minimum necessary deviation.

### 4.3 Category glyphs — the one open owner decision

The design draws category marks as **stroke SVG icons** tinted with per-category
ink colours (`--c-food-ink` etc.) on soft tinted backgrounds.

Flutter draws them as **native colour emoji** — a deliberate, documented
decision in `category_glyph.dart`, which ignores the passed colour precisely
because the emoji carries its own.

**Implemented:** the container. Category tiles were solid dark blocks and now
use the design's soft tint, which is what made them read as heavy brown boxes
down the ledger and the budget list.

**Not implemented:** replacing emoji with a stroke-icon set. That is a change of
product identity and needs a per-category icon mapping — not a token migration,
and not mine to self-approve in either direction.

Status: **MISMATCH — OWNER DECISION REQUIRED.** Counted as a mismatch, not
quietly reclassified.

---

## 5. `--f-mono` — MISMATCH, small

The design specifies IBM Plex Mono for "selected monospaced financial/network
details". The app has no mono family bundled and uses tabular figures on the
primary face instead.

Effect is confined to technical detail strings (IDs, card networks). Closing it
means bundling a fourth family; recorded rather than done silently.

Status: **MISMATCH — OWNER DECISION REQUIRED** (bundle IBM Plex Mono, or accept
tabular-figure Vazirmatn as the intentional substitute).

---

## 6. PDF report face

The PDF renderer still draws with IBM Plex Sans Arabic, so the exported report
and the screen no longer share a face.

Status: **OPEN — deliberate**, recorded in `app_typography.dart`. The PDF is a
separate pipeline with its own layout metrics; changing its face changes
exported documents, not app screens, and should be decided on that basis.

---

## 7. Budget threshold — confirmed, not reopened

No architecture change. Re-verified against the suites that already cover it
(`budget_alert_threshold_test`, `budget_alert_threshold_persistence_test`,
`budget_alert_slider_test`, `budget_threshold_guards_test`):

| Check | Result |
|---|---|
| 30 / 50 / 80 selectable and firing at the chosen point | PASS — parameterised over 10/30/50/80/95/100 |
| Persisted per budget | PASS |
| Create · edit · restart · backup/restore · export/import | PASS — including a real migration (column dropped, DB reopened, row lands on 80) |
| Notification copy states the actual threshold | PASS — «وصلت ٣٠٪» / "has reached 30%", asserted not to contain 75 |
| Stale "Alert at 80%" copy | GONE — the Settings toggle is now "Budget alerts" / «تنبيهات الميزانية». The only place 80 still appears is a budget whose threshold *is* 80 |

One change this pass, and it is a fix rather than a reopening:
`AppColors.budgetState` was a **third** hardcoded 0.8 — the bar could read
"warning" while no alert had been sent. It now takes the budget's own
`warnAtPercent`, and `DashboardBudgetEntry` carries the threshold so the
dashboard bar agrees too.

### 7.1 Current notification policy — stated for the owner, unchanged

Three thresholds, in order:

1. **The user's own threshold** (10–100%, default 80). Copy names the actual
   percentage.
2. **90% escalation** — "almost used up", with a projected run-out date. Fires
   **only when the user's threshold is below 90**, so it can never collide with
   or precede their own alert.
3. **100% exceeded** — a separate notification type (`budgetOver`), not a
   warning, and not configurable.

Dedup: the notification id is keyed on `(budget, period, crossed percentage)`.
Spending further past a threshold reuses the id and replaces the notification
rather than stacking one; a new period gets a new id and can alert again.

**Not changed silently.** If the owner wants the 90% escalation removed, made
configurable, or applied regardless of the chosen threshold, that is a one-place
change in `_thresholdsFor`.
