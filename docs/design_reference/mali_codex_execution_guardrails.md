# Mali Codex Execution Guardrails

Purpose: binding rules for Codex or any implementation agent after this reference analysis. Stop after docs unless the user explicitly starts a phase.

## Golden Rule

This redesign is UI-only until the user explicitly approves otherwise. Do not change business logic to match a reference image.

## Forbidden Scope

Unless explicitly approved, never touch:

- `app/lib/domain/**`
- `app/lib/data/**`
- `app/lib/engine/**`
- `supabase/**`
- database/schema files
- parser logic
- AI categorization logic
- repositories
- use cases
- auth logic
- backup logic
- capture bridge logic
- router behavior

Also avoid:

- `git add .`
- broad cleanup commits
- generated file churn unless required by an approved l10n change
- deleting tests or weakening tests
- package additions without approval

## Allowed Scope By Phase

- Phase 0: docs/reports only.
- Phase 1: `app/lib/core/theme/**` and reports.
- Phase 2: `app/lib/features/common/**`, selected theme files if required, reports.
- Phase 3+: only the screen files named in the migration phase plus shared components already approved.

If implementation appears to require changing a provider, route, repository, use case, database table, parser, AI client, auth, backup, or capture bridge, stop and ask.

## Required Gates For Every Phase

Run from `app/`:

```bash
flutter analyze
flutter test
flutter build macos --debug
```

If these fail because of pre-existing repo state, document the exact failure in the phase report and do not declare the phase complete.

## Required Reports For Every Phase

Create:

- `docs/redesign/phase_N_<name>_report.md`
- `docs/redesign/phase_N_<name>_self_review.md`

Reports must include:

- files changed.
- reference images used.
- what was intentionally not copied.
- logic/provider/route safety confirmation.
- commands run and results.
- screenshots taken or why screenshots were not possible.
- remaining risks.

## Commit Rules

- Do not commit unless the user explicitly asks or the phase instruction explicitly says to commit.
- If committing, stage only phase files. Never use `git add .`.
- Commit only if all gates pass or the user explicitly approves committing despite known failures.
- Stop after each phase.

## Reference Usage Rules

Use reference images for:

- color direction.
- typography hierarchy.
- component composition.
- spacing/radius.
- card/button/sheet/state style.
- screen hierarchy.

Do not use reference images to:

- invent new app features.
- invent fake data.
- add unsupported routes.
- copy copyrighted logos.
- copy external app identity.
- copy Payvo directly.
- add bank/payment features.
- add real merchant logos.

## Performance Guardrails

- Avoid heavy blur everywhere.
- Avoid nested `BackdropFilter` in scrollable content.
- Avoid excessive glow and neon.
- Avoid complex shaders.
- Avoid animated backgrounds unless optional and approved.
- Avoid image-heavy UI.
- Avoid generated 3D assets in Flutter unless simple static SVG/widget assets are approved.
- Keep long lists cheap; no per-row expensive effects.

## Localization And Direction Guardrails

- Arabic-first, RTL-safe.
- Preserve English/LTR support.
- Use `EdgeInsetsDirectional`, `AlignmentDirectional`, and direction-aware icons.
- Use LTR islands for:
  - email.
  - OTP.
  - card/account numbers.
  - currency codes.
  - recovery codes.
  - transaction references.
- Do not add hardcoded user-facing strings if the surrounding screen uses l10n.
- If ARB changes are approved, run l10n generation and include generated files deliberately.

## Visual Token Guardrails

- Use `context.colors` and theme tokens.
- Do not introduce hardcoded feature gradients.
- Do not add per-screen typography helpers.
- Use `AppTypography`.
- Use shared buttons/cards/sheets/states.
- Prefer semantic colors for warning/danger/success.
- Check dark and light mode contrast.

## Current Repo Safety Notes

- The repo already has unrelated dirty files. Do not revert or stage them unless the user explicitly asks.
- The requested reference image folder was absent; images analyzed were in `app/docs/images/`.
- Current app code has no dedicated Smart Inbox route; treat Smart Inbox as dashboard/transactions/sheet surfaces unless routing is approved.
- Current app code maps `/profile` to `SettingsScreen`.
- Current app code has guest onboarding paths; a design can prefer email-first, but implementation must not remove guest logic without explicit approval.

## Phase Start Checklist

Before starting a phase:

- Confirm the exact phase number and scope with the user or the active task.
- Run `git status --short`.
- Read this guardrail file.
- Read `mali_reference_analysis.md`, `mali_visual_adaptation_spec.md`, and `mali_screen_migration_plan.md`.
- Identify allowed files.
- Identify forbidden files.
- Plan verification commands.

## Phase Stop Checklist

Before final response for a phase:

- Run `git status --short`.
- Run required gates or document why they could not run.
- Confirm forbidden scope was not touched.
- Confirm no fake data/features/logos were added.
- Confirm reports exist.
- Do not continue into the next phase.
