# Mali — Implementation Safety Contract (Redesign Phase)

> Binding rules for any agent/contributor (incl. Antigravity) executing the redesign.
> Source of truth: `docs/design_audit/*` and `docs/redesign/screen_by_screen_redesign_spec.md`.
> The redesign is **UI-only** unless a later, explicitly-named phase says otherwise.
> Paths relative to `app/`. Project gate commands live in `app/CLAUDE.md`.

---

## 0. Golden rule

**This is a presentation-layer redesign.** Widgets, layout, tokens, and shared components may change.
**Data, domain, and platform logic may not** — see §3. If a redesign task appears to *require* a logic
change, STOP and escalate; do not expand scope unilaterally.

---

## 1. No big-bang rewrite

- Work **one screen (or one shared component) per phase**, in the order in
  `screen_by_screen_redesign_spec.md` → "Suggested sequencing".
- Each phase must compile, pass gates (§9), and be independently reviewable.
- Do **not** delete-and-rewrite a screen wholesale; refactor incrementally so diffs stay reviewable.
- Foundations (shared `AppHeader`, `SheetScaffold`, token cleanup, button-bug sweep) ship **before**
  per-screen visual work, so screens migrate onto stable primitives.

## 2. No business-logic changes during UI phases

- UI phases touch only: widget trees, layout, styling, shared UI components, and **read-only** wiring
  to existing providers (`ref.watch`/`ref.read` of providers that already exist).
- You may **add** a presentation-only provider (e.g. a UI tab index) but must not alter the meaning of
  existing data providers.
- No changes to query logic, filtering semantics, dedup, rate-limits, or thresholds during UI phases.

## 3. Do NOT change (unless a dedicated, named non-UI phase requires it)

- **Parsing logic:** `lib/engine/parser/**` (`ParserEngine`, normalizer, bank profiles, isolate).
- **Transaction logic:** `lib/domain/usecases/add_transaction_usecase.dart`,
  `ingest_captured_message_usecase.dart`, dedup (`TransactionDedup`, dedup store).
- **AI / categorization:** `lib/engine/ai/**` (`ai_parser_client`, `grounding_check`,
  `ai_sender_failure_tracker`), `lib/engine/categorization/**`, `supabase/functions/parse-sms/**`.
- **Providers (semantics):** `lib/core/di/app_providers.dart`, all `*_providers.dart` — you may read
  them; do not change what they compute.
- **Storage:** `lib/data/db/**` (Drift schema, `_targetSchemaVersion`, migrations), repositories
  in `lib/data/repositories/**`, `database_key_store`.
- **Auth / session / backup:** `lib/core/auth/**`, `lib/core/session/app_session.dart`,
  `lib/features/backup/**`, `lib/core/security/**`.
- **Capture platform bridge:** `lib/features/capture/services/**`, `sms_background_handler.dart`,
  native channels.
- **Tests:** `test/**` — do not weaken or delete tests to make UI changes pass. A test may only change
  if a UI contract it asserts legitimately changed (e.g. a widget key/label), and that change must be
  called out in the phase notes.
- **Edge Functions & secrets:** no redeploys or secret changes during UI phases.

## 4. No hardcoded colors

- All colors come from `context.colors` (`AppColors`) — never literal `Color(0x…)` / `Colors.x`
  in feature code (white/black for on-gradient text is the only allowed exception, and prefer a token).
- Existing offenders to fix as encountered (see audit `visual_system_current.md`): bills `_BillsHero`
  blues (`#046E9B/034E73/012438`), onboarding preview (`#050A12/060D19`), `AppShadows.cta` (`#006B8F`),
  per-card inline `BoxShadow`s.

## 5. No per-screen typography clones

- Use `AppTypography.*` only. **Delete/replace** the per-screen `_alex(...)` helpers in
  `onboarding_screen.dart`, `method_screen.dart`, `auth_screen.dart`, `goals_screen.dart`,
  `goal_form_screen.dart`, `budget_form_screen.dart` as those screens are touched.
- If a needed style is missing, **add it to `AppTypography`**, don't inline a new `TextStyle`.

## 6. No new gradient styles unless added to tokens

- Every gradient must be a named entry in `lib/core/theme/app_gradients.dart`.
- Collapse the existing parallel blues into a single brand gradient set; do not introduce a new ad-hoc
  `LinearGradient` in a feature file.

## 7. Shared components are mandatory where they exist

- Every screen uses `AppScreenScaffold` + the unified `AppHeader` (to be built) — no bespoke headers.
- Cards: `AppCard` / `AppMetricCard` / `AppInsightCard` / the merged `ProgressItemCard` (budgets/goals/
  bills) — no new one-off card containers.
- Buttons: `AppButton`/`AppPrimaryButton` or themed `FilledButton`/`OutlinedButton` — no ad-hoc styled
  buttons.
- Rows: `AppTransactionRow` for any transaction row (retire legacy `TransactionRow` in
  `common/widgets.dart`).
- States: `AppEmptyState`, the standardized `LoadingState` (`PremiumSkeletonPage`), and a new shared
  `AppErrorState`.

## 8. All sheets must use a shared `SheetScaffold`

- Every `showModalBottomSheet` (~20 call sites, listed in audit `component_map.md`) must route through
  one `SheetScaffold` providing: RTL `Directionality`, drag handle, max-height constraint, scrollable
  body (prevents the recurring overflow bugs), and optional blur.
- No raw `Container`/`Column` sheet bodies; no per-sheet literal `28` radius.

## 9. `c.primary` must never be a blind button background

- `c.primary` is **white in dark mode** (`AppColors.dark.primary = #FFFFFF`). It must never be used as
  a `backgroundColor` for a button/CTA without explicit contrast validation against its foreground.
- Default interactive background is `c.cta`. Sweep remaining offenders (audit lists: settings sheets,
  `sms_permission_screen`, `foundation_home_screen`, `change_category_sheet`, `force_update_screen`,
  `app_lock_gate`).
- Add a review check: grep for `backgroundColor: c.primary` must return zero in feature code.

## 10. Run gates after **every** phase (from `app/`)

```bash
flutter analyze            # must be 0 issues
flutter test               # must pass (full suite, ~293 tests)
flutter gen-l10n           # only if ARB files changed
```

- A phase is not "done" until analyze is clean AND the full test suite is green.
- Never commit/push automatically — leave changes in the working tree for review (per `app/CLAUDE.md`).

## 11. Preserve localization & direction & theme in every phase

- **Arabic + English**: do not hardcode new user-facing strings that bypass l10n where l10n is used;
  prefer moving strings into `app_ar.arb` / `app_en.arb` (then `flutter gen-l10n`). Don't break the
  English locale further.
- **RTL + LTR**: use `EdgeInsetsDirectional`, `AlignmentDirectional`, and direction-aware icons; rely on
  the shared `SheetScaffold`/`AppScreenScaffold` for `Directionality` instead of re-wrapping per widget.
- **Dark + light**: verify every changed screen in both modes; check contrast of text on gradients and
  of any new surfaces. No mode may regress.
- **Text scaling**: respect the existing `textScaler` clamp (0.8–1.25 in `app.dart`); new fixed-height
  rows/chips must scale (use `MediaQuery.textScalerOf` like the date-range chips do).

## 12. Per-phase definition of done

- [ ] Only UI/presentation files changed (verify `git status` against §3 list).
- [ ] Uses shared `AppScreenScaffold` + `AppHeader` (+ `SheetScaffold` for sheets).
- [ ] Zero hardcoded colors / gradients / typography clones introduced.
- [ ] No `c.primary` button backgrounds without contrast proof.
- [ ] `flutter analyze` clean; `flutter test` green.
- [ ] Verified in AR + EN, RTL, dark + light.
- [ ] Matches the screen's "Acceptance criteria" in the redesign spec.
- [ ] Diff is screen/component-scoped and reviewable (no unrelated churn).

---

## Escalation triggers (STOP and ask)

- A redesign step needs a provider's output to change, a new DB column, or a parser/AI tweak.
- A shared-component change would ripple into >1 screen unexpectedly.
- A test must change to pass.
- A string has no l10n key and adding one would touch generated files broadly.
