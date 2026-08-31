# Current Release Status

**HEAD:** `3901bf4a` · **Updated:** 2026-08-31
**Authoritative execution order:** [`../QIRSH_PRODUCTION_RELEASE_RUNBOOK.md`](../QIRSH_PRODUCTION_RELEASE_RUNBOOK.md)

## One-line state

Source and local work are complete and gate-green. The production database and
the legal site now exist and are verified. Everything still open needs an
account, a physical device, a third-party approval, or a deferred configuration
pass — none of it is source work.

**Not release-ready.** No signed build exists, and Play approval for
`RECEIVE_SMS` is a precondition for Android publication regardless of build
state.

## Gate evidence

Strict `REQUIRE_ALL_GATES=1 tools/ci_gates.sh` at HEAD `8a97a9ba`. **This is a
record of that run, not of the current HEAD** — the auto-SMS and legal work
landed after it, so the counts below have moved and the full suite has not been
re-run since. Re-run before any signed build.

```
{"passed":12,"failed":0,"tool_missing":0,"caller_skipped":0,"artifact_pending":1,"strict":1}
ALL RUN GATES PASSED
```

| Gate | Result |
|---|---|
| Migration lint (numbering + SECURITY DEFINER + rollback coverage) | ✓ |
| Deno tests, all 24 functions | ✓ |
| Deno lint | ✓ |
| `flutter analyze` | ✓ 0 issues |
| `flutter test` bulk | ✓ 2840 passed |
| `flutter test` crypto (serialised) | ✓ 24 passed |
| Node contract tests | ✓ |
| Admin authorisation tests | ✓ 113 |
| l10n freshness | ✓ |
| MALI-034 architecture guard (6 checks) | ✓ |
| MALI-037 dependency policy | ✓ |

`artifact_pending: 1` is the iOS packaging inventory, which needs a built
`Runner.app`. It is never classified as a pass and is deferred to a post-build
step — the static Info.plist / privacy-manifest contract does run.

## Backend state

**The production backend exists.** Superseded 2026-08-31 — this section
previously said no production project had been created.

| Ref | What | Rule |
|---|---|---|
| `rjwphwsefnuotpbtuycf` | **production** — created, linked, migrated | the only deploy target |
| `vrombzdgwqjjiijbidqb` | old production | ZERO contact |
| `dpdukyozedajelflkeix` | evidence staging | ZERO contact |
| `bdhqjijscwdzqwqanygv` | "Nbjg" | ZERO contact — no longer linked |

Verify `cat supabase/.temp/project-ref` equals `rjwphwsefnuotpbtuycf` before any
remote operation. It does at this HEAD.

| Item | State |
|---|---|
| Migrations `0001`–`0092` | **applied**, chain verified against `supabase_migrations.schema_migrations` |
| Post-migration verification | **done** — public schema, seeds (21 categories incl. `all_expenses`), RLS policies, SECURITY DEFINER functions, extensions, cron jobs, grants |
| `backups` storage bucket | **private**, verified |
| `0092` | applied — closed a live anon-writable exposure created by `0087`; the dry-run harness was fixed to model Supabase's default privileges, which is why `0087` shipped unnoticed |
| **Edge Functions (24)** | **NOT DEPLOYED — BLOCKED.** Supabase Management API returns 403 on the Functions endpoints; raised with Supabase Support |

Migrations applied is **not** the same as backend ready. Nothing that depends on
an Edge Function works in production today.

## Everything else still open

| Item | State |
|---|---|
| Legal site + privacy policy | **DONE** — `https://qirsh.site` over TLS; source and live aligned, hash-verified ([`../04_Legal/legal_release_checklist.md`](../04_Legal/legal_release_checklist.md)) |
| Android upload keystore | **generated and verified** locally; not enrolled in Play App Signing |
| **Google Play `RECEIVE_SMS` approval** | **PENDING** — declaration drafted, not submitted |
| **Physical Android SMS QA** | **PENDING** — no Android device has ever been connected to this machine |
| Apple portal reconciliation | **DEFERRED** — needs client 2FA ([`../17_Apple_Production/portal_audit.md`](../17_Apple_Production/portal_audit.md)) |
| Codemagic production configuration | **DEFERRED** to one final consolidated pass; `LEGAL_BASE_URL=https://qirsh.site` recorded as pending |
| Signed release build | **NOT CREATED** |

## Capability state

All exact-money transports are `unknown`, so financial cloud sync is off by
design. See [`../07_Cloud_Capabilities/capability_model.md`](../07_Cloud_Capabilities/capability_model.md).

## Related

- Completed work: [`completed_source_local_work.md`](completed_source_local_work.md)
- Remaining work: [`remaining_external_work.md`](remaining_external_work.md)
- Blocker history: [`QIRSH_RELEASE_TRACK.md`](QIRSH_RELEASE_TRACK.md)
