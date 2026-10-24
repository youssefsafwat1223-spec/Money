# account_deletion_fence — execution blocked

**ACTUAL RUNTIME BLOCKED.** Supabase CLI 2.117.0 has no reviewed enforceable
pre-launch loopback binding, fresh credential and pinned image contract in this
unit. `run.sh` and `preflight.sh` refuse all actual phases. They contain no
Docker/Supabase/database/network command, SQL execution, configuration copy,
service start/stop or target deletion. A marker, environment override or valid
planning input cannot enable execution. No real stack has been qualified here.

The prior scripts' hash-derived invalid/colliding ports, inherited broad config,
post-start-only binding check, unconditional no-fence check and marker-only
teardown have been removed with the unsafe executor. This is a safe refusal,
not a replacement functioning provisioner or a backend test PASS.

## Four-path source and mock scope

| File | Actual behavior |
| --- | --- |
| `run.sh` | Requires a phase, then delegates to the refusal gate. |
| `preflight.sh` | Validates argument/path metadata read-only, then returns nonzero with `RUNTIME_BLOCKED`. Unsafe paths refuse earlier. Its embedded pure helpers check synthetic planning inputs only. |
| `harness_safety_test.py` | Standard-library pure validation and hermetic CLI refusal tests. Fixed interpreters, fresh child environment, inert service stubs, private temporary files; no sockets, SQL parser, real services or network. |
| `README.md` | This boundary and remaining runtime requirements. |

The existing CLI spellings `--runtime-dir`, `--phase` and preflight
`--post-start` do not authorize an operation. A well-formed request returns
nonzero with a named missing-capability refusal. New/empty absolute paths must
be outside home/repository, use a conservative `qirsh-fence-*` token, have no
symlink component and avoid protected projects. Existing nonempty targets,
including counterfeit marker files, are preserved and refused. Teardown does
not delete anything.

The pure plan helper checks explicit distinct ports in 1024..65535, exact
127.0.0.1 bindings, no occupied-port assertions, only the four necessary service
roles, exact image digests and fresh-task credential provenance with no inherited
environment references. Those are untrusted input assertions. They establish
neither availability nor binding enforcement, fresh credentials, image presence
or a race-free launch. No port probe/reservation is attempted.

Pure manifest checks compare exact synthetic identities and typed resource IDs;
partial-start subsets confer no real cleanup authority. Pure phase checks use
separate supplied catalog observations: baseline/apply require baseline state,
concurrency/rollback require the applied source, and post-rollback requires
restoration. A phase marker alone cannot pass. These tests never simulate
PostgreSQL, establish database state or authorize a phase.

## Qualification boundary

The source author does not execute checks. Root must first inspect the frozen
four-path diff and test containment, then run only the separately approved
syntax and hermetic mock checks. Such results must be called **SOURCE+MOCK**;
**ACTUAL RUNTIME BLOCKED** remains separate. Positive pure checks mean validation
passed; positive CLI controls mean the unconditional refusal was reached. No
fake successful startup or test-only production bypass exists.

## Required before any future real runtime

A separate reviewed scope and owner approval must establish an enforceable
pre-launch loopback-only runtime with pinned CLI/images and no implicit pulls;
fresh task-issued synthetic credentials and a minimal clean configuration;
explicit ports for every exposed service and contained launch failure; exact
task-created container/network/volume ownership and safe partial cleanup; and
real phase/catalog/restoration observations bound to source/runtime identity.
Protect `qirsh_beta1_sync_rc5800`, `qirsh_proof`, `frasaaaaa` and all shared
resources. No linked project, hosted credential, `.env`, global prune or
marker-only deletion is acceptable. This unit supplies none of that approval.

SQL drafts, migrations, application and tracked backend configuration remain
unchanged. Even a later qualified synthetic stack cannot alone prove production
adoption, complete personal-data erasure, Apple revocation, challenge issuance,
KMS custody/destruction, retention enforcement, every writer or effects already
dispatched. The concurrency matrix needs its own coverage review.
