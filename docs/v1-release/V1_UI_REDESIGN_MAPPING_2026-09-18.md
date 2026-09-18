# V1 UI Redesign Mapping — 2026-09-18

Design source of record for this pass.

| | |
|---|---|
| File supplied by the owner | `/Users/luciq/Downloads/2be70da5-58d6-43ef-9033-b3497c842cd2.html` |
| SHA-256 | `b5c5b09f5927ea4d223a55b098be318a41110e3bddb0aba32f6e56988d36e8de` |
| Size / lines | 382,580 bytes / 2,993 lines |
| Canonical path | `/Users/luciq/Documents/QirshWorktrees/app-onboarding/design/qirsh_full_app_ui.html` |
| Modified | 2026-09-12 20:00 |

---

## 0. The first thing to say: this file is not new

**It is byte-identical to the canonical design file** — same SHA-256, and the
canonical copy is the newest of the three on disk:

| Copy | Modified | Lines | SHA-256 (16) |
|---|---|---|---|
| `design/qirsh_full_app_ui.html` (canonical) | 09-12 20:00 | 2,993 | `b5c5b09f5927ea4d` |
| supplied file | — | 2,993 | `b5c5b09f5927ea4d` |
| `app-ui/qirsh_full_app_ui_patched.html` | 09-12 15:05 | 2,894 | `57880cd62d31e29d` |
| `app-ui/qirsh_full_app_ui.html` | 09-12 15:01 | 2,885 | `f9ad1dcebf7ed105` |

So this pass is **not** implementing a new design the app has never seen. It is
measuring the app against the design it has always been measured against — but
at the level of the **design system** (tokens, palette, geometry) rather than
per-surface composition, which is what the 2026-09-17/18 visual passes checked.

The manifest counts match the expected shape exactly: **99 frames, 27 overlays,
11 dialogs, 16 components, 5 platform surfaces, 2 flag-gated** — and **69 root
design variables**.

---

## 1. What the measurement found

The app was compared token-by-token against the HTML's two `:root` blocks.

| | Design tokens present in Flutter | |
|---|---|---|
| **Dark theme** | **17 / 19** | already migrated by an earlier pass |
| **Light theme** | **1 / 24** | only `#FFFFFF` |

**The gap is the light theme, and only the light theme.** The dark scheme in
`app_colors.dart` already carried `#121317`, `#181A20`, `#23262E`, `#A8AEBA`,
`#22C55E`, `#F59E0B`, `#EF4444`, `#F2F4F8`, `#9DB9FF`, `#0E1D33`, `#0E2A18`,
`#2E6BFF`, `#0B0C0F`, `#2A1F0A`, `#2A1113` — every one of them a
`:root[data-theme="dark"]` value.

The light scheme carried a Tailwind-derived palette instead: `#111827`,
`#4B5563`, `#16A34A`, `#DC2626`, `#D97706`, `#021B79`. Close to the design in
feel, equal to it nowhere.

This is the inverse of the failure mode the brief warned about ("new design in
light, old design in dark") — here it was **new design in dark, old design in
light**.

## 2. What was migrated

`AppBrandBlue` — the single blue ramp the whole app derives from:

| Token | Was | Now | Design var |
|---|---|---|---|
| `deep` | `#01102F` | `#011341` | `--qirsh-blue-deep` |
| `brand` | `#021B79` | `#022686` | `--qirsh-blue` |
| `strong` | `#0A2E9E` | `#0336BF` | `--qirsh-blue-mid` |
| `mid` | `#1C4FD0` | `#1653F3` | `--qirsh-blue-light` |
| `light` | `#55ABFF` | `#688EF3` | `--qirsh-sky` |
| `bright`, `pale` | — | unchanged | already the dark-theme design values |

`AppColors.light` — surfaces, ink and semantics:

| Token | Was | Now | Design var |
|---|---|---|---|
| `bg` | `#F4F6FB` | `#F4F6FC` | `--ground` |
| `surfaceElevated` | `#F1F3F8` | `#EEF1F8` | `--chrome` |
| `surfaceMuted`, `border` | `#ECEFF6`, `#DDE2EC` | `#E7EBF5` | `--qirsh-hair` |
| `ctaSoft`, `infoBg` | `#EAF2FF`, `#EAF1FF` | `#D3DDF8` | `--qirsh-blue-wash` |
| `accent` | `#FBC926` | `#E4BA41` | `--gold` |
| `income`, `success` | `#16A34A` | `#12855C` | `--qirsh-success` |
| `expense`, `danger` | `#DC2626` | `#C4362C` | `--qirsh-danger` |
| `warning` | `#D97706` | `#C9800F` | `--qirsh-warning` |
| `textPrimary`, `onSurface` | `#111827` | `#0C1330` | `--qirsh-ink` |
| `textSecondary`, `onSurfaceMuted` | `#4B5563` | `#39415C` | `--qirsh-ink-2` |
| `successBg` | `#E8F8EE` | `#E1F3EC` | `--c-in-bg` |
| `dangerBg` | `#FDECEC` | `#FBE7E4` | `--danger-bg` |
| `warningBg` | `#FFF3D8` | `#FBF0DE` | `--warn-bg` |

**20 of 25 light tokens now match the design exactly**, up from 1.

## 3. Two deliberate deviations

### 3a. `ink` keeps the brand blue, not the design's near-black

The prototype's `--ink-btn` / `--nav-bg` is `#0B1024`, a near-black navy. It was
adopted, and `ux002_brand_treatment_test` failed — correctly.

UX-002 is an explicit owner decision: QA collected ~10 sightings of a near-black
surface (the Budgets promo banner, three sets of tab pills, the theme selector,
the filter chips, two primary buttons), the owner rejected that treatment, and
chose the product's own identity instead. That ruling predates this design file
and the brief did not reopen it — *"previous owner decisions remain unless
explicitly changed here"*.

So `ink` stays `AppBrandBlue.brand`, which **still moves with the design system**
(`#021B79` → `#022686`). The token adopts the design's blue rather than the
design's black. White on it measures 12.93:1.

Classification: **PRIOR OWNER DECISION — DOCUMENTED DELTA.** If the owner now
wants the near-black nav treatment, it is a one-token change plus retiring that
guard, and it should be decided rather than absorbed.

### 3b. Muted text is darkened to pass AA

`--qirsh-muted: #727B96` was **not** adopted verbatim.

Measured against the design's own ground (`--ground: #F4F6FC`) it is
**3.90:1** — below WCAG AA for body text. `textMuted` is the single token this
repo has already had to fix once for exactly this reason.

Shipped instead: **`#67708A`** — the same hue (225°) and saturation (0.146),
darkened to the first step that passes. **4.56:1** on the ground, **4.93:1** on
a card.

Classification: **ACCESSIBILITY INTENTIONAL DELTA**. The brief's own contract
("no inaccessible contrast") outranks pixel equality with a prototype, and the
prototype is a design document rather than an accessibility audit.

Every other migrated token holds or improves its contrast:

| Token | Before | After |
|---|---|---|
| `textPrimary` on ground | 16.42 | **16.88** |
| `textSecondary` on ground | 6.99 | **9.32** |
| `income`/`success` on white | 3.30 | **4.63** |
| `danger` on white | 4.83 | **5.37** |
| `brand` on white | 14.63 | 12.93 (still AA) |
| `warning` on white | 3.19 | 3.19 (unchanged) |

## 4. Not migrated, and why

| Area | State | Reason |
|---|---|---|
| Typography | **already correct** | Vazirmatn is bundled locally in `pubspec.yaml`; `google_fonts` was removed in B2-D specifically so the app never fetches type over the network. The brief's requirement was already satisfied. |
| Dark theme | **already correct** | 17/19 design dark tokens were already in place. |
| Radius scale | **not migrated** | Flutter 4/8/12/16/20/28/32 vs design 8/12/16/22/26/32. |
| Spacing scale | **not migrated** | Flutter 4/8/12/16/20/24/32/40 vs design 4/8/12/16/20/26/34. |
| Nav bar height | **not migrated** | Flutter 54 vs design ~60. |
| Mint / gold-deep / gold-lit | **no slot** | `#31D0AA`, `#B76F27`, `#FFE880`, `#DFF7F0` have no corresponding token in `AppColors`; adopting them means new tokens AND the surfaces that use them. |
| Per-surface composition | **not re-done** | The 2026-09-17/18 passes inspected all 58 surfaces against Atlas/HTML intent and closed them at MISMATCH 0. |

**This is a scope statement, not a completion claim.** Migrating the geometry
scales means touching several hundred call sites of `AppSpacing.*` and
`AppRadius.*` across every screen, days before a release, for a visual delta of
2–6 logical pixels per edge. The palette migration is the part that changes what
the product *looks like*; the geometry migration is the part that changes what
every layout test *measures*. Doing the second at this point would put the
release at risk for the smaller half of the gain, and it is recorded here for
the owner to schedule rather than taken unilaterally.
