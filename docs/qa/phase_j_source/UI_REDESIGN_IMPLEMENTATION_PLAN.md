<!-- PROVENANCE: copied from `demo-docker/UI_REDESIGN_IMPLEMENTATION_PLAN.md`, which is an untracked local
     demo/working directory. Cross-checked during Phase J source recovery; cited by the closure matrix.
     Tracked here so the authoritative artifact survives loss of that
     directory. The original is left in place; this copy is the one of
     record. -->

# UI/UX Redesign — Implementation Plan (PLAN ONLY — no code yet)

2026-08-27 · derived from `UI_UX_REDESIGN_BACKLOG.md` (32 entries) · execution in Main.
Ordering principle: **system before screens** — every screen redesign done before the
design-system pass would be repainted twice.

## Phase A — Design-system foundations (unblocks everything)
| # | items | why first |
|---|---|---|
| A1 | **UX-002** hardcoded black/white → tokenised `AppColors` roles | the largest collector; every later screen inherits it |
| A2 | **UX-032** vertical-rhythm rule («مفيش widget يدخل في widget») as a shared layout primitive (Home card list gap/section spacing) | one primitive, applied everywhere |
| A3 | **UX-001** money precision — single `MoneyText` formatter (exact, per-currency scale) | kills the rounding self-contradictions (budget card) |
| A4 | **UX-012 + UX-009** bottom-nav legibility + floating-nav content inset | shell-level, affects all tabs |
| Verify | golden/widget tests per token role; screenshot pass on Home/Budgets/Reports in both themes |

## Phase B — HIGH screen redesigns
| # | items | notes |
|---|---|---|
| B1 | **UX-003** budget bottom sheet — **full redesign, not recoloring** (operator directive preserved verbatim) | after A1/A3 so it lands once |
| B2 | **UX-013** accounts screen shows balances | needs A3 formatter |
| B3 | **UX-022** refunds visible in Reports | data exists; presentation + filter chip |
| B4 | **UX-025** goals list: deadline + required daily rate on cards | detail sheet already computes both |
| Verify | widget tests per screen + operator visual pass on device |

## Phase C — MEDIUM screen batch (grouped by surface)
- **Home:** UX-007 (selector names account) · UX-010 (empty-section placeholders) · UX-011 (pull-to-refresh) · UX-008 (logo)
- **Plans:** UX-004/005/006/027 (linked accounts, visual language, closed-plans, affordances)
- **Subscriptions:** UX-023 (installments in total) · UX-024 (account-scope visibility)
- **Goals/Budgets:** UX-026 («السجل» tab contents)
- **Settings/System:** UX-028 (duplicate header) · UX-029 (nav-hub restructure) · UX-031 (message-centre dates) · UX-030 (privacy claim) · UX-015/021 (jargon) · UX-014 (truncation) · UX-020 («0 من 0»)
- Verify: per-surface widget tests; one consolidated device pass per surface group.

## Phase D — Admin-panel UX (separate track, no app rebuilds)
UX-016/017/018/019 + labels. Can run parallel to B/C.

## Rules of engagement
1. One phase = one review cycle with the operator; no phase starts without sign-off.
2. Every change traces to a backlog ID; no drive-by restyling.
3. `flutter analyze` clean + targeted widget tests green per phase; goldens updated deliberately.
4. Device visual confirmation (operator screenshots) closes each phase — same protocol as Phase-3 QA.
