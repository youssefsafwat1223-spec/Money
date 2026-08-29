# Current Release Status

**HEAD:** `576be89a` · **Updated:** 2026-08-29
**Authoritative execution order:** [`../QIRSH_PRODUCTION_RELEASE_RUNBOOK.md`](../QIRSH_PRODUCTION_RELEASE_RUNBOOK.md)

## One-line state

Source and local work are complete and gate-green. Every remaining item needs an
account, a device, a domain, or explicit production authorisation.

## Gate evidence

Strict `REQUIRE_ALL_GATES=1 tools/ci_gates.sh` at HEAD `8a97a9ba`:

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

**No production backend exists yet.** The production Supabase project has not
been created. Three refs must not be confused:

| Ref | What | Rule |
|---|---|---|
| *(to be created)* | new production | the only deploy target |
| `vrombzdgwqjjiijbidqb` | old production | ZERO contact |
| `dpdukyozedajelflkeix` | evidence staging | ZERO contact |
| `bdhqjijscwdzqwqanygv` | "Nbjg", currently linked | **not a target** — unlink first |

## Capability state

All exact-money transports are `unknown`, so financial cloud sync is off by
design. See [`../07_Cloud_Capabilities/capability_model.md`](../07_Cloud_Capabilities/capability_model.md).

## Related

- Completed work: [`completed_source_local_work.md`](completed_source_local_work.md)
- Remaining work: [`remaining_external_work.md`](remaining_external_work.md)
- Blocker history: [`QIRSH_RELEASE_TRACK.md`](QIRSH_RELEASE_TRACK.md)
