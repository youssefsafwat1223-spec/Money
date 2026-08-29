# Completed Source / Local Work — Do Not Repeat

Each entry is implemented **and** verified locally, with evidence. This exists so
completed work is never redone.

> `[x]` here means "done at the level claimed". Where something is source-complete
> but awaits live proof, it says so explicitly in the last section.

## Financial correctness

| Work | Evidence path |
|---|---|
| Exact money as integer minor units | `app/lib/domain/finance/money.dart`, `currency_scale.dart` |
| Money-typed display formatter (R-8) | `app/lib/domain/finance/money_format.dart`, `app/lib/features/common/money_text.dart` |
| Currency-scale table drift (R-8a) | display scale derives from the canonical registry; `KMF` no longer missing |
| Schema v29 → v31 planning conversion | `app/lib/data/db/app_database.dart` |
| Netting contract preserved, made visible | `financial_semantics.dart` unchanged; Reports shows gross / refunds / net |
| 3-decimal currency capture | migration `0091`; `fmtCaptureMoney` |
| Budget card self-contradiction (UX-001) | `_BudgetAmountTile` takes `Money`, not a pre-formatted `String` |

## Security / privacy / sync

| Work | Evidence path |
|---|---|
| Consent authority, fail-closed | `app/lib/core/privacy/consent_authority.dart` |
| Egress inventory: 12 gated, 1 exempt, 0 open | `app/test/architecture/egress_inventory_test.dart` |
| SQLCipher, fail-closed on a missing extension | `app/lib/data/db/app_database.dart` |
| DB key held in the platform keychain | `app/lib/data/db/database_key_store.dart` |
| Guarded tombstones, CAS conflict typing | Phase 9K–9N; live 2-client gate, zero PGRST116 |
| Supabase-primary authority retired (MALI-034) | `tools/check_arch_guard.sh` (6 checks) |
| Sign-out preserves unsynced data (MALI-053n) | `app/lib/features/settings/settings_screen.dart` |

## Product surfaces

| Work | Evidence path |
|---|---|
| **Phase J UI/UX: 39/39 findings closed**, 10 new found and fixed | `docs/audit/QIRSH_PHASE_J_UIUX_CLOSURE.md` |
| On-device AI classifier (OD-13), zero per-request cost | `app/lib/engine/intelligence/merchant_classifier.dart` |
| Parser evidence gate — `passed` now requires golden tests | migration `0087` |
| Admin operator-trust findings UX-017…021 | `admin/tests/admin-ux-closure.test.mjs` |

## Release preparation

| Work | Evidence path |
|---|---|
| Migrations 0084–0091 written and reviewed | `supabase/migrations/` |
| **Rollbacks 0084–0091** — had been missing entirely | `supabase/rollback/` |
| Rollback coverage enforced by lint, floor 0084 | `supabase/tools/check_migrations.sh` |
| Fresh-DB dry-run: all 91 apply in filename order | `supabase/tools/dryrun_migrations.sh` |
| Rollback round-trip proven | 0084–0091 re-apply after rollback |
| Legal documents written and fact-checked against code | `docs/legal/PRIVACY_POLICY.md`, `docs/legal/TERMS.md` |
| Legal static-site generator, dependency-free | `tools/build_legal_site.py` |
| IBM Plex OFL from authoritative local sources | `app/assets/fonts/IBMPlexSansArabic-OFL.txt` |
| Font licences registered so they are reachable in-app | `app/lib/core/theme/font_licenses.dart` |
| `LEGAL_BASE_URL` added to all three CI workflows | `codemagic.yaml` |
| Empty-define trap fixed (hostless URI) | `app/lib/core/config/legal_urls.dart` |
| Android signing fails closed, no debug-key fallback | `app/test/architecture/android_release_signing_test.dart` (10 tests) |
| Repository coherence guards | `app/test/architecture/head_completeness_test.dart` |
| Root cleanup + documentation taxonomy | this workspace, `docs/` |

## Source-complete but awaiting LIVE proof

These are **not** finished. The code is right; production has not confirmed it.
Do not mark any of them complete on the strength of the source alone.

| Item | Source state | Still needs |
|---|---|---|
| exact PUSH transport | implemented, gated `unknown` | byte-exact production evidence |
| exact PULL transport | implemented, gated `unknown` | byte-exact production evidence |
| planning server currency | implemented, gated `unknown` | migration `0077` deployed + transport proof |
| APNs delivery | code and secrets contract ready | a real device and a real APNs key |
| UX-035 large-value rendering | exactness fixed; legibility floor added | device repro at maximum text scale |
| Android release build | config verified by 10 tests | a build on a machine with unrestricted Gradle network |
