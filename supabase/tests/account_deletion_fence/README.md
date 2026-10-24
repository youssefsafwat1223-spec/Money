# account_deletion_fence — isolated test harness (WRITTEN, NOT EXECUTED)

Status: **none of these files has ever been run.** They were authored and only
syntax-checked (`bash -n`, `deno check`). Nothing here has touched Supabase,
Docker, a database or the network. No result in this directory proves anything.

Contract (from `deletion-global-fence-design.md`, "Bounded next authorization"):

* a newly provisioned, uniquely named, **loopback-only** local Supabase stack
  built from the **unmodified current migrations**, with the real Auth,
  Storage, PostgREST and extensions (no `dryrun_scaffold.sql` stand-ins);
* synthetic users and synthetic credentials only; no hosted credential, no
  `.env`, no linked project, no `supabase/config.toml` edit;
* the draft migration `supabase/drafts/account_deletion_fence/fence.sql` is
  applied **only to that disposable database** and only in phase `apply`.

## Files

| File | Purpose |
| --- | --- |
| `preflight.sh` | Refuses unsafe targets (non-loopback, shared/pre-existing resources, linked project, missing marker, missing tools/capabilities). Read-only. |
| `run.sh` | Provisions the disposable runtime and runs one phase: `baseline`, `apply`, `concurrency`, `rollback`, `teardown`. |
| `baseline.sql` | Read-only catalog report of the CURRENT authority: signatures, owners, ACLs, policies, triggers, Auth FK actions, extensions. |
| `acl.sql` | Assertions on the POST-fence catalog (raises on any violated expectation). |
| `concurrency_test.ts` | Multi-session (psql subprocess) and real Auth/Storage API schedules. Skips itself unless `FENCE_DB_URL` is set. |

## Command contract (planned; do not run without owner/Astra approval)

```
bash supabase/tests/account_deletion_fence/preflight.sh --runtime-dir <new dir>
bash supabase/tests/account_deletion_fence/run.sh --runtime-dir <same dir> --phase baseline
bash supabase/tests/account_deletion_fence/run.sh --runtime-dir <same dir> --phase apply
bash supabase/tests/account_deletion_fence/run.sh --runtime-dir <same dir> --phase concurrency
bash supabase/tests/account_deletion_fence/run.sh --runtime-dir <same dir> --phase rollback
bash supabase/tests/account_deletion_fence/run.sh --runtime-dir <same dir> --phase teardown
```

`<new dir>` must not exist (or be empty), be an absolute path outside the
repository, and is removed by `teardown`.

## What a green run would still NOT prove

* completed deletion: Apple revocation, KMS sealing and the challenge issuer
  are outside this harness;
* production ACL/owner/membership (a local stack's defaults are not production's);
* every Edge writer; only the schedules in `concurrency_test.ts`;
* APNs/Gemini effects already dispatched.

If an image, extension or capability is missing, stop and report the exact
missing item. Never substitute a hosted environment, schema stubs or a skipped
proof.
