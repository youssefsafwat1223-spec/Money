# New Supabase Production Project — Bootstrap

Detail for runbook [§2](../QIRSH_PRODUCTION_RELEASE_RUNBOOK.md#phase-2--new-supabase-production-project).

## Why a new project

The old production ref (`vrombzdgwqjjiijbidqb`) and evidence staging
(`dpdukyozedajelflkeix`) both carry history from the audit period and are under a
zero-contact rule. Production starts clean so the schema is exactly the
0001–0092 chain with no manual drift.

## Wrong-project protection

`supabase/.temp/project-ref` currently holds `bdhqjijscwdzqwqanygv` ("Nbjg") —
not a deploy target. It is gitignored, so it is local state, but **any deploy run
today goes there and appears to succeed.**

Before every remote command:

```bash
cat supabase/.temp/project-ref     # must equal the intended production ref
```

Treat a mismatch as a full stop.

## The five values, and where each belongs

| Value | Secret? | Ships in the app? | Destination |
|---|---|---|---|
| Project Ref | no | no | CLI linking, verification |
| Project URL | no | **yes** | `--dart-define=SUPABASE_URL` |
| anon public key | no — public by design | **yes** | `--dart-define=SUPABASE_ANON_KEY` |
| service_role key | **YES** | **never** | platform-injected only |
| DB password / connection string | **YES** | never | local `psql` runs |

The anon key identifies the project; **RLS** grants access. The service_role key
**bypasses RLS entirely** — it must never reach the app, a commit, or a log.

## Region

`eu-central-1` (Frankfurt) is the usual best latency for Saudi, Egypt and UAE
users. Pick a Gulf region if one is offered.

## After creation, before anything else

Confirm the `public` schema has no application tables. The migrations create
everything; a hand-made table collides.
