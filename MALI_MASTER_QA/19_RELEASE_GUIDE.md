# 19 — Release Guide

Related: [20_FINAL_REPORT_TEMPLATE.md](20_FINAL_REPORT_TEMPLATE.md), [21_CHECKLISTS.md](21_CHECKLISTS.md), [27_DEPLOYMENT_GUIDE.md](27_DEPLOYMENT_GUIDE.md), [28_PRODUCTION_RUNBOOK.md](28_PRODUCTION_RUNBOOK.md).

## 1. What "a release" means here

Mali has two independent release surfaces that do not have to move together:

1. **App release** — a new iOS/Android build (version bump, App Store/Play Store submission, or Codemagic-built IPA for sideloading).
2. **Backend release** — a new Supabase migration and/or Edge Function deployment, and/or a feature-flag rollout change.

A backend release can ship without an app release (e.g., a bug fix in an Edge Function). An app release almost always requires the backend release it depends on to have shipped first (the app should never assume a schema/RPC/flag exists before it's actually live).

## 2. Pre-release checklist (app)

- [ ] `flutter analyze` — 0 issues.
- [ ] `flutter test` — all pass.
- [ ] `flutter gen-l10n` run and committed if any `.arb` file changed.
- [ ] Version bumped in `pubspec.yaml` (`version: X.Y.Z+build`) — build number strictly increasing.
- [ ] No debug-only test seam reachable in a release build (grep for `QA_REFRESH_TOKEN` and any other `kDebugMode`-gated seam, confirm the gate is actually present — see [07_SECURITY.md](07_SECURITY.md) §6).
- [ ] No temporary diagnostic `print`/`debugPrint` left in a hot path from an in-progress investigation (see [17_BUG_WORKFLOW.md](17_BUG_WORKFLOW.md) §3).
- [ ] iOS: both `Runner` and `BankMessageShortcuts` schemes build successfully; the three `SharedCaptureStore.swift` copies are byte-identical (`md5` check — see [06_FLUTTER.md](06_FLUTTER.md) §10).
- [ ] Android: SMS permission handling unchanged from the last store-approved version, or explicitly reviewed for policy compliance if changed.
- [ ] This handbook updated for any architecture/schema/flag change in the release (see README.md "Maintenance").

## 3. Pre-release checklist (backend)

- [ ] Every new migration has a matching rollback file.
- [ ] Every new/changed migration verified against live row counts/shapes before being written (see [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) §2).
- [ ] `supabase migration list` shows local and remote in sync.
- [ ] Only the Edge Functions actually affected by the change are deployed (determined via `grep -rl "_shared/<changed-module>"`, not a blanket redeploy).
- [ ] `deno check`/`deno test` pass for every changed function/module.
- [ ] RLS unchanged unless the change explicitly intends an RLS change, in which case it's called out prominently in the release notes.
- [ ] No global feature flag's `rollout_percent`/`is_active` changed as a side effect of an unrelated migration.

## 4. Feature-flag rollout procedure (the only sanctioned path to "go live" for a Supabase-primary migration)

```mermaid
flowchart TD
    A[Flag created, OFF, rollout_percent=0] --> B[Per-user override testing\n(dedicated QA users only)]
    B --> C{All 13-step notification QA\n+ full test matrix green?}
    C -- no --> B
    C -- yes --> D[Explicit human approval\nto raise rollout_percent]
    D --> E[Staged rollout: e.g. 1% → 5% → 25% → 100%]
    E --> F[Monitor after each stage\n(24-48h minimum per stage)]
    F --> G{Any regression signal?}
    G -- yes --> H[Roll back to 0%\ninvestigate before resuming]
    G -- no --> E
    E --> I[100% — flag effectively permanent,\nold code path scheduled for cleanup]
```

Each stage bump is a **separate, explicit, human-approved action** — never automated, never bundled into a code-deploy PR's scope. See [00_SYSTEM_PROMPT.md](00_SYSTEM_PROMPT.md) Rule 1 and §8.

## 5. Rollback procedure

- **App rollback**: revert to the previous build via the store's phased-release halt mechanism (App Store Connect / Play Console), or re-sideload the previous IPA for Codemagic-distributed builds. The app has no server-side "kill switch" for its own code — a bad app release can only be fixed by shipping a new one or halting the rollout of the bad one.
- **Backend rollback**: run the matching `supabase/rollback/NNNN_*.sql` file. Verify afterward using the same post-migration checklist as a forward migration (§3 above, [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) §3).
- **Flag rollback**: set `rollout_percent` back to 0 (or `is_active = false`) — this is instant and requires no code deploy, which is exactly why the flag-gated migration pattern exists (see [03_ARCHITECTURE.md](03_ARCHITECTURE.md) §4). This is always the fastest rollback lever for a Supabase-primary regression and should be reached for first, before considering a code or schema rollback.

## 6. Release notes discipline

Every release (app or backend) gets a short, factual changelog entry: what changed, why, and — critically for this project — which feature flags (if any) were touched and their before/after state. See [20_FINAL_REPORT_TEMPLATE.md](20_FINAL_REPORT_TEMPLATE.md) for the detailed report format used for significant changes.

## 7. CI (Codemagic)

Two workflows in `codemagic.yaml`:

- `ios-unsigned-sideload` — unsigned IPA for Sideloadly, no paid Apple Developer account required. Useful for QA distribution without App Store review latency.
- `ios-signed-release` — signed IPA requiring the Apple Developer Program (needed for App Groups entitlement used by the capture pipeline's shared storage, and for actual App Store/TestFlight distribution).

Supabase keys are injected via the `supabase` variable group in Codemagic settings — never hardcoded into `codemagic.yaml` itself.

## 8. Who approves what

| Action | Approval needed |
|---|---|
| Merging a code change with passing gates | Standard code review |
| Applying a non-destructive migration | Standard review; live-verified per [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) |
| Applying a destructive migration | Explicit, separate sign-off, with the rollback file's data-loss statement read and accepted |
| Deploying an Edge Function | Standard review + affected-function-scoping check |
| Raising a flag's `rollout_percent` above 0 for the first time | Explicit human approval, session-specific |
| Raising a flag to 100% / removing its gate | Explicit human approval, treated as a full production cutover decision |
| Committing an AI agent's changes | Explicit user instruction to commit, every time — never assumed from a prior approval |
