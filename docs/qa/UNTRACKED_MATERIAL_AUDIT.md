# Untracked Material — Repository-Safety Audit

Performed at HEAD `2d3d3616`, before the release-baseline certification.

**Question:** does any authoritative QA finding, closure evidence, release
artifact, or source of truth exist **only** in an untracked location?

**Answer:** it did. Nine artifacts were promoted into tracked locations. The
remainder is disposable, runtime, or already-captured working material.

## Promoted into tracking

| From | To | Why it was authoritative |
|---|---|---|
| `demo-docker/UI_UX_REDESIGN_BACKLOG.md` | `docs/qa/phase_j_source/` | **the** Phase J finding list (37 IDs) that closure is measured against |
| `demo-docker/DEMO_GUIDED_QA.md` | `docs/qa/phase_j_source/` | session log the findings originated from |
| `demo-docker/UI_REDESIGN_IMPLEMENTATION_PLAN.md` | `docs/qa/phase_j_source/` | cross-checked during source recovery |
| `demo-docker/PHASE6_PUSH_PREFLIGHT.md` | `docs/audit/` | release preflight evidence |
| `demo-docker/AUDIT_HANDOFF_DF-002.md` | `docs/audit/` | became migration `0088` |
| `demo-docker/AUDIT_HANDOFF_F-016.md` | `docs/audit/` | audit handoff |
| `demo-docker/PARKED_ITEMS_RECONCILIATION_DESIGN.md` | `docs/audit/` | exact-money parking contract design record |
| `research/sms_model_lab/migration_check/verify_0091.sh` | `supabase/tools/migration_check/` | **cited by migration `0091`** as what caught a real defect |
| `research/…/seed_0002_rules.sql` | `supabase/tools/migration_check/` | the harness's input |

Copies, not moves — the originals stay so the demo environment keeps working.
The tracked copy is the one of record and carries a provenance header.

## Deliberately left untracked

| Item | Classification | Reasoning |
|---|---|---|
| `demo-docker/` app + `node_modules` (≈15,700 js) | runtime/build | a working copy of the app; the canonical source is `app/` |
| `demo-docker/DEMO_RUNBOOK.md` | disposable runtime | instructions for a local Docker demo; states it is "**not** production, staging, or a deployment" |
| `research/sms_model_lab/reports/` (37 reports) | working evidence | the **conclusions and benchmark numbers are already tracked** in `docs/architecture/QIRSH_AI_ARCHITECTURE.md` (442 lines, incl. n=3320 / 98.0% vs 93.4% baseline). These are the raw workings behind a captured decision |
| `research/corpus/` | data | message corpus; consent-governed, not a release artifact |

## Recorded uncertainty

`demo-docker/admin/PROMOTION_MANIFEST.md` and
`demo-docker/admin/REDESIGN_INVENTORY.md` (137 + 108 lines) classify an admin
redesign session's files as promotable. They are **left untracked** because they
describe a promotion that never happened, against a stale baseline (`12f36726`),
in a workspace with no `.git`.

They are session-scoped rather than product-authoritative — but this is a
judgement call, not a certainty. They were **not deleted**, and if the admin
redesign is revived they should be reconsidered.

## Verification

```bash
# nothing in the tracked tree resolves an untracked path at runtime
git grep -nE "File\(['\"](demo-docker|research)/" -- ':!docs' ':!demo-docker'
# expect: no output
```

Both directories are cited in tracked comments as provenance. No tracked test,
build or migration **reads** either at runtime, so neither is load-bearing.
