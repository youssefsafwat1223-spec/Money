# Qirsh Production

**The one folder to open when the question is "what do I do next?"**

Everything from the current source/local-complete state through a live App Store
and Google Play release. Start with the master runbook and work down it.

> **[QIRSH_PRODUCTION_RELEASE_RUNBOOK.md](QIRSH_PRODUCTION_RELEASE_RUNBOOK.md)** ← start here

---

## Current state in one line

Source and local work are **complete and gate-green**. Everything remaining needs
an account, a device, a domain, or explicit production authorisation.

**Production Supabase project: does not exist yet.** It will be created new. The
project currently linked on this machine (`bdhqjijscwdzqwqanygv`, "Nbjg") is
**not** the production target and must not be treated as one — see runbook §0.

---

## What is here

| Folder | Contains |
|---|---|
| `01_Current_Status/` | where the project actually stands, what is done, what is left |
| `02_Supabase/` | creating and provisioning the **new** production backend |
| `03_AI/` | the on-device classifier and the optional Gemini fallback |
| `04_Legal/` | hosting the privacy policy and terms, and wiring the URL |
| `05_Apple/` | developer account, APNs, signing, device QA, App Store Connect |
| `06_Android/` | keystore, device QA, Play Console |
| `07_Cloud_Capabilities/` | the capability model and the PUSH→PULL activation path |
| `08_Device_QA/` | physical-device QA with pass/fail criteria, including UX-035 |
| `09_Beta/` + `10_Store_Release/` | TestFlight, Play internal, metadata, rollout, rollback |
| `11_Rollback_Recovery/` + `12_Archive/` | superseded documents, kept with a pointer to their replacement |

---

## What is deliberately NOT here

This folder organises **documentation**. It does not restructure the application.

Anything a build, test, migration or CI job resolves by path stays exactly where
it is, and is referenced from here by its canonical path. Moving those to make a
folder tidy would break the product to improve a directory listing.

Canonical locations that stay put:

| Kind | Path |
|---|---|
| Flutter app | `app/` |
| Migrations | `supabase/migrations/0001…0092` |
| Migration rollbacks | `supabase/rollback/` |
| Edge Functions | `supabase/functions/` (24) |
| Legal source documents | `docs/legal/PRIVACY_POLICY.md`, `docs/legal/TERMS.md` |
| Historical audits / plans / handoffs | `docs/audit/`, `docs/plans/`, `docs/handoff/`, `docs/qa/` |
| Legal site generator | `tools/build_legal_site.py` |
| Gate runner | `tools/ci_gates.sh` |
| Migration lint | `supabase/tools/check_migrations.sh` |
| Migration dry-run | `supabase/tools/dryrun_migrations.sh` |
| CI workflows | `codemagic.yaml` |
| Android signing | `app/android/app/build.gradle.kts`, `app/android/key.properties.example` |
| iOS config | `app/ios/Runner/Info.plist`, `app/ios/Runner/Runner.entitlements` |
| Capability providers | `app/lib/data/sync/exact_transport_capability.dart` |

Several `docs/*.md` files are read **by tests at runtime** (for example
`docs/CAPABILITY_ACTIVATION_RUNBOOK.md` and `docs/legal/*`). Those are not moved
either; this workspace links to them.

---

## Sources of truth

To avoid two documents disagreeing:

| Question | Authoritative source |
|---|---|
| What do I do next? | `QIRSH_PRODUCTION_RELEASE_RUNBOOK.md` (this folder) |
| What is left, and who does it? | [`01_Current_Status/remaining_external_work.md`](01_Current_Status/remaining_external_work.md) |
| What was already finished? | [`01_Current_Status/completed_source_local_work.md`](01_Current_Status/completed_source_local_work.md) |
| UI/UX finding closure | `docs/audit/QIRSH_PHASE_J_UIUX_CLOSURE.md` |
| Historical audit narrative | `docs/audit/QIRSH_LONG_RUN_REPORT.md` |
| Release-blocker history | [`01_Current_Status/QIRSH_RELEASE_TRACK.md`](01_Current_Status/QIRSH_RELEASE_TRACK.md) |

Documents superseded by this workspace are in [`12_Archive/`](12_Archive/), each with a note
saying what replaced it. Nothing was deleted.
