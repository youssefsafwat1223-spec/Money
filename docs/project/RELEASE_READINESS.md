# Qirsh — release readiness

**Classification as of 2026-09-02: ENGINEERING COMPLETE.**

Not BETA READY. Not a Release Candidate. Not Production Ready.

## What the label means here

| Label | Met? | Why |
|---|---|---|
| NOT READY | passed | No known executable engineering blocker remains. The one that did — Android SMS capture being unreachable — is fixed. |
| **ENGINEERING COMPLETE** | **current** | Code and integration are complete; canonical CI is green; every remaining item needs hardware, an external account, or a production database this machine cannot read. |
| BETA READY | **no** | Requires device QA. No physical device has ever been attached to this machine, and no simulator or emulator run has been performed either. |
| RELEASE CANDIDATE | **no** | Additionally requires the Play restricted-permission approval and a verified production migration ledger. |
| PRODUCTION READY | **no** | Additionally requires deployed migrations, deployed Edge Functions, configured AdMob units, and store approval. |

## The honest boundary

**ENGINEERING COMPLETE ≠ VALIDATED.** Specifically:

- Affiliate fixture tests are **not** real network validation — no network is contracted.
- Zero simulator runs are **not** simulator validation.
- Migration source is **not** a deployed migration — and for 0084–0092 the repo contradicts itself about which it is.
- Edge Function tests are **not** deployed Edge Functions; four affiliate functions have never executed against the live project.
- An AdMob component is **not** a configured AdMob account; no production ad unit exists.
- A written device QA plan is **not** device QA.

## What has actually been verified

Canonical CI (`tools/ci_gates.sh`, the repository's own authority — 11 gates,
with a truthfulness contract that forbids counting a skip as a pass):
migration lint, Deno tests + lint, `flutter analyze`, the full Flutter suite in
two stages, Node contract tests, skip-manifest enforcement, admin authorization
tests, l10n freshness, the MALI-034 architecture guard, and the dependency
policy. The iOS packaging gate is artifact-dependent and defers to a post-build
check.

Static and architectural guarantees are strong: 430 test files, egress
inventory with every network call classified, backup/wipe/restore coverage
guards, forward-only schema enforcement, and a new reachability guard that fails
if a permission-gated feature loses its last production caller.

## What has never been verified

Everything that needs hardware or a counterparty. See `RELEASE_BLOCKERS.md`
RB-4, RB-5 and RB-6 for the three that gate a production claim, and
`EXTERNAL_REQUIREMENTS.md` for the full dependency list.

## Path to the next label

1. **→ BETA READY:** connect an Android device; run the SMS device QA matrix and
   the banner QA checklist. Resolve the migration ledger from the Supabase
   dashboard.
2. **→ RELEASE CANDIDATE:** reconcile the three SMS disclosure documents, submit
   the Play permissions declaration and Data Safety form, obtain approval.
   Restore Apple portal access and complete iOS device QA.
3. **→ PRODUCTION READY:** deploy the verified migration set and the Edge
   Functions, configure AdMob units and `app-ads.txt`, then enable flags
   deliberately and one at a time.
