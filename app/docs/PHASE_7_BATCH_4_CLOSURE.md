# Phase 7 · Batch 4 — Hardening (privacy, CI coverage, deps, test integrity, ops, docs)

Batch-4 is hardening only — no UI/sync/financial-semantics/backup-crypto changes,
no CAS activation, no migration deployment, no dependency upgrades, no bundle
rename. Canonical brand is **Qirsh / قِرش**; the `com.youssefsafwat.mali` bundle
id and `money_companion` package (technical codename "Mali") are unchanged.

See also: `PHASE_7_BATCH_3_CLOSURE.md`, `PHASE_7_MALI_034_CLOSURE.md`,
`PHASE_7_MALI_040_CLOSURE.md`.

## Finding classifications (every Phase-7-relevant remaining finding)

| Finding | Classification | Batch-4 action |
|---|---|---|
| MALI-035 (CLAUDE.md drift) | OPEN LOCAL → **Code complete·LV** | fixed the dangerous "all optional/offline stub" claim, schema 4→29, volatile test counts→"via ci_gates.sh", stale branch ref, "App name: Mali"→brand=Qirsh/codename=Mali |
| MALI-037 (CVE/license gate) | OPEN LOCAL (offline part) + EXTERNAL (CVE) | added `tools/check_deps_policy.sh` (offline: lockfile present, no git deps, path-dep allowlist) as a mandatory gate stage; CVE/outdated registry scans remain external |
| MALI-039 (financial PII in diagnostics) | **Code complete·LV** at HEAD | already remediated (redacting debugPrint sink, Diag API, parameterized SQL, PII-log-snapshot regression); added the hostile-imported-id SQL regression |
| MALI-042 (per-fn Deno tests uncI) | OPEN LOCAL → **Code complete·LV** | Deno stage now runs the whole functions tree (catalog-delta injection guard included) |
| MALI-043 (brand + privacy) | OPEN LOCAL (privacy) → **Code complete·LV**; brand DECIDED (Qirsh) | removed unjustified `NSLocationWhenInUseUsageDescription` + static privacy-manifest regression; branding sweep confirms Qirsh/قرش canonical, no user-facing leftovers |
| MALI-044 (metrics WITH CHECK(true)) | **source-remediated (0072), deployment EXTERNAL** | migration `0072_backend_security_hardening` already drops the policy + revokes INSERT + rate-limited RPC; 0072 stays in the undeployed 0068–0076 set; NO new migration required |
| MALI-066n (CI visibility) | Partial → **Code complete·LV (local)** | per-function Deno + conditional iOS packaging wired; ci.yml already invokes ci_gates.sh (single source); codemagic reconciliation = documented follow-up |
| MALI-067n (test integrity) | OPEN LOCAL → **Code complete·LV** | source-text inventory reconciled; converted the one code-symbol-spelling test to an import-graph contract; retained legitimate manifest/data contracts; DB no-close/suppression/randomized-order already closed by MALI-040 |
| MALI-077n (ops lows) | OPEN LOCAL → **Code complete·LV** (Kotlin path documented; native handlers external) | codemagic email + keystore comment fixed; caller-less Dart `consumePendingSharedMessages` deleted; Kotlin `com/example/` path documented as cosmetic (not moved); native handlers' removal deferred (external compile) |
| MALI-021 | **SUPERSEDED** | dead-file/PDF sweep folded into MALI-076n/065n/077n — verify-only, no new work |
| MALI-036 | Code complete (limits) — **EXTERNAL** | hosted-CI run + compat matrix; ci.yml uses ci_gates.sh |
| MALI-026 | **DEFERRED** (P8) | fixed-precision money — out of scope |

## Commits (small, focused; not pushed)

`fe8c9267` B4-1 privacy (NSLocation) → `69dae030` B4-2 MALI-039 hostile-id →
`ca004e63` B4-3 test integrity → `78134977` B4-4 CI wiring →
`2dfa41d2` B4-5 deps policy → `ffc1795b` B4-6 ops lows → `eabbc718` B4-7 docs+branding.

## Decisions applied

- **Decision 1 (brand):** canonical user-facing brand = **Qirsh / قِرش**; bundle id
  `com.youssefsafwat.mali`, `money_companion`, `assets/qirsh/`, db/migration names
  unchanged. English product-name surfaces use "Qirsh".
- **Decision 2 (Kotlin path):** `android/app/src/main/kotlin/com/example/money_companion/`
  is **cosmetic** — all four `.kt` files declare `package com.youssefsafwat.mali`,
  matching Gradle `namespace`/`applicationId` and the manifest `.MainActivity`;
  Kotlin/Gradle compile by package declaration, not path, so the build is correct.
  NOT moved (and Android compile verification is external — no SDK locally); it
  does not block local closure.

## Mandatory gate stays deterministic/offline

`check_deps_policy.sh` is network-free (reads only pubspec.yaml/lock). CVE feeds,
`dart pub outdated`, and ecosystem advisories are deliberately kept OUT of the
mandatory gate (they would tie gate determinism to registry availability). The
iOS packaging built-bundle check is CONDITIONAL/external (runs only against a
real `Runner.app`, else UNAVAILABLE — never faked); its static Info.plist/privacy
contract runs deterministically in `flutter test`.

## Batch-4 closure gate

Canonical `tools/ci_gates.sh` run **once** from the committed clean tree
`11727d81`, **first attempt green**:

```
mandatory gates passed : 13
mandatory gates failed : 0
tools unavailable      : 0
skip/ignore manifest   : satisfied
ALL LOCAL GATES PASSED
```

- flutter test bulk (crypto excluded): **1589 passed** (incl. the 6 new B4 tests).
- flutter test crypto (serialized Argon2, `--concurrency=1`): **24 passed**.
- deno tests (ALL functions, MALI-042): pass; 2 live cases self-skip.
- architecture guard **6/6**; **MALI-037 dependency policy 3/3** (offline).
- iOS packaging inventory: a simulator `Runner.app` happened to be present, so the
  built-bundle check RAN and passed (bundle id, PrivacyInfo, extension inventory).
  Note: that bundle's freshness is incidental — the structural inventory it checks
  is what passed; the source Info.plist privacy contract (NSLocation absent) is
  verified independently by `flutter test`. Freshly-built SIGNED archive evidence
  remains external.

**Bookkeeping:** executable Batch-4 closure verified at `11727d81`;
documentation-only closure record at the commit that adds this section.

**Status:** Phase 7 / Batch 4 — Code complete — locally verified; privacy-surface,
CI gate coverage, dependency-hygiene, test integrity, ops-config, and
documentation truthfulness are reconciled and guarded. Remaining evidence is
external (signed builds, physical devices, live backend/APNs, hosted CI matrix,
CVE feed) per the external-evidence ledger. Not pushed. Batch 5 and MALI-026 NOT
started.

## External-evidence ledger (remains pending after local Batch-4)

- MALI-036: hosted-CI run + device/OS compatibility matrix.
- MALI-043/031/033/…: signed IPA/AAB, physical iPhone/Android, App-Store review
  (privacy manifest), Play policy, store privacy report.
- MALI-044/024/054n/060n/075n/076n: live Supabase/RLS + APNs + Edge deploy;
  migrations 0068–0076 remain undeployed.
- MALI-022/057n: live CAS enablement (CAS stays off).
- MALI-037: CVE feed / registry-freshness scan (network).
- MALI-077n: native handler removal (Swift/Kotlin) + Kotlin path move — Android/iOS
  compile verification.
- `verify_ios_packaging.sh`: freshly-built `Runner.app` archive evidence.

## Invariants preserved

schema **v29**, `kServerRevisionCas=false`, migration 0070 inactive, 0068–0076
undeployed, backup envelope **v3**. No migration deployment. No MALI-026. No Batch 5.
