# Safe Redesign Guardrails — Mali App

This document establishes the strict architectural boundaries, safety invariants, and tooling constraints that must be observed during the visual redesign of the Mali Flutter application.

---

## 1. Architectural Integrity & Boundaries

The Mali application follows a layered clean architecture. To prevent regressions and ensure code safety:
*   **Zero Business Logic Alterations**: Business logic resides in domain entities, use cases, services, repositories, and state providers. Under no circumstances should any code in the following directories or of the following types be modified:
    *   `lib/domain/` (Entities, Use Cases, Value Objects)
    *   `lib/data/` (Repositories, DB schemas, API clients, local storage)
    *   `lib/core/backend/`, `lib/core/di/`, `lib/core/security/`, `lib/core/session/`
    *   Any file ending in `_provider.dart`, `_repository.dart`, `_use_case.dart`, or `_service.dart` (except visual themes or UI-bound local controllers).
*   **Presentation Layer Separation**: UI modifications must be strictly confined to screen widgets, visual theme configurations, and generic presentation helper widgets.
*   **Database & Schema Safety**: The local Drift schema (`lib/data/db/app_database.dart`) is untouchable. No columns, indices, tables, or seed loaders may be changed, added, or removed.
*   **Supabase and External Services Integrity**: Supabase configurations, tables mapping, sync mechanisms, metrics loggers, and Sentry integrations must remain exactly as they are.

---

## 2. Invariant Rules of Code Modifications

*   **No Dummy / Fake Data Injection**: Keep the layout powered entirely by existing production models and providers. Do not populate lists with hardcoded mock text or mock numbers to test visual sizing.
*   **Exclusion of Unimplemented Conceptual Features**: The visual design strategy contains several future feature ideas (e.g., merchant map visualization, swipe-to-confirm Smart Inbox, split-bill toggle, privacy blur mode, biometric animation, advanced interactive chart gestures, 3D onboarding artwork, new AI confidence score, new budget health score). None of these features should be built or simulated. We only redesign the *visual presentation* of components that are already implemented.
*   **Arabic (RTL) and LTR Bidirectional Invariance**: Mali is Arabic-first. Every UI modification must respect bidirectional alignment.
    *   Use `Directionality.of(context)` or text direction properties to dynamically adjust alignments.
    *   Numbers and financial balances must remain LTR formatted, read left-to-right (e.g. `1,250 SAR` or `١،٢٥٠ ر.س`), while descriptions and headers must read RTL in Arabic.
    *   Do not replace `AppSpacing` or layout grids with rigid structural widgets that break under RTL mirroring.

---

## 3. State Management & Data Binding Rules

*   **Watch, Do Not Modify**: When listening to Riverpod providers, use `.watch` to display data. Never perform logic inside the build method that overrides or resets the state of a provider.
*   **Form Validations and Save Logic**: The input sheets and transaction creation forms must preserve their exact validation criteria and database insertion routines. Only decorate the input borders, colors, and overlays.

---

## 4. Git & Commit Guidelines

*   **Explicit Staging ONLY**: Never run `git add .` or `git add -A`. You must explicitly stage files by their relative path (e.g., `git add lib/core/theme/app_colors.dart`).
*   **No Stash Disruption**: Never run `git stash pop` or `git stash clear` without explicit instruction.
*   **Phase-by-Phase Segregation**: Do not cross phases. Finish and verify a phase completely, run all required CLI verification tools, generate the phase reports, commit the work, and stop execution.

---

## 5. Tooling & Verification Pipeline

Before committing any code or transitioning to a new phase, the entire project must pass the following pipeline:
1.  `flutter analyze` — Must return zero lint errors or warnings.
2.  `flutter test` — All tests must pass successfully.
3.  Debug Build compile check — Command: `flutter build apk --debug` (or platform equivalent like macos/ios if building). If compilation fails, stop and revert immediately.
4.  Phase Verification Report — Must be created under `docs/redesign/` named `phase_[X]_report.md`.
5.  Self-Review Checklist — Must be completed and attached to the report.
