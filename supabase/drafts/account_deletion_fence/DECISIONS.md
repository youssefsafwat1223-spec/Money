# Account-deletion fence — D-SQL3 decision record

**STATUS (2026-10-24):** promoted to migration `0117_account_deletion_fence` (rollback `supabase/rollback/0117_account_deletion_fence_rollback.sql`).
Qualified on a disposable loopback-only Supabase stack (migrate, apply, acl, concurrency, drain, rollback with an identical baseline) and
reviewed by a fresh Opus 5.5 security review (findings F1-F4 below were fixed afterwards and need a re-run of the real-DB lifecycle).
**Production apply requires the owner's explicit approval.** **The migration copy is canonical:** `supabase/migrations/0117_account_deletion_fence.sql`
and `supabase/rollback/0117_account_deletion_fence_rollback.sql` must stay byte-identical to `fence.sql` / `rollback.sql` in this directory,
which remain the generator's working copy (`gen_rpc_bodies.py --check` fails when they differ). The text below was written during drafting; where it says
"proposed" or "unparsed" read it together with this status and the qualification and review sections.

Historical migration evidence is at base `81c59422cfce498e1efab4d2f5cee4124a982593`; actual deployed catalogs/default grants
are unknown. The updated source inventory and operation matrix are in
`/Users/luciq/Documents/Codex/beta1-claude-p1/codex-round9-recovery-20261016/D-retry-run/inventory.md`.
The prior `D-SQL2` inventory remains historical evidence, superseded by this inventory for changed controls. Existing
`D-SQL3` logs and all earlier snapshots were preserved. The original SQL3 unit changed only `fence.sql`, `rollback.sql` and this record; its bounded retry correction changes only
`fence.sql` and this record (rollback privilege/object scope is unchanged).
`gen_rpc_bodies.py` remains byte-identical. Generated regions still reproduce without writing. The coordinator, tests,
Edge/app files, migrations and execution harness were not changed.

Product input remains: deletion is permanent, no grace period; the app says deleted only after server completion.

## E1.1 — Lease validation and bounded locking argument

`lease_job` now locks the job by `job_id` alone, then samples `clock_timestamp()` into `v_now`, then checks token (including
non-null), generation, running state and non-null unexpired lease. Every caller, including heartbeat, uses that operation.
A blocker that merely holds the row lock without updating it no longer depends on locking-SELECT predicate re-evaluation.
`lease_peek` is only a lock-free discovery hint for purge; purge validates again after its blocking account-gate wait and job
lock, and once more after erasure/verification. These are explicit validation boundaries, not a claim about every statement,
the eventual COMMIT instant or observed database behavior. Lock-only/update blockers and heartbeat expiry still need E8 proof.

Blocking account-gate acquisition in accept/purge occurs before either holds a job row. Ordinary writers' install/account
gates are try-locks; failure aborts the whole mutation (`55P03`). Purge takes exclusive install try-locks after its account
and job locks. That reverse order adds no blocking gate wait. Same-install ordinary callers take a shared install gate;
same-account writers still contend on their exclusive account gate. Different accounts/installs need not conflict (Q21).

E1.2 adds the domain-row ordering omitted by SQL2: acceptance locks an **existing** open job FOR UPDATE before locking and
revalidating its challenge; completion locks job then deletes challenges. Existing-job FK-backed scope/receipt inserts
therefore never wait for that job while holding the challenge first. New acceptance may lock a challenge before INSERTing a
new job, but that new row is not visible to another job holder before commit. Challenge consumed/expiry checks still occur
after challenge locking. The old universal domain-row-before-job ordering claim is withdrawn.

This is a source argument for the identified cycles, not complete lock-order/deadlock proof. Application triggers, cascades,
FK actions, material/receipt/workset rows, rollback quiescence and actual lock encoding remain qualification work.
`assert_gated` still requires the exclusive advisory gate in this backend/database and re-admits the discovered owner. A
session advisory lock on the same key can satisfy the lock predicate; this code itself takes transaction locks only (O6).

## E1 — Authority, attribution and privileges

The narrow NOLOGIN/NOINHERIT/NOSUPERUSER/NOBYPASSRLS owner remains. It owns the fence schema, its functions/tables and the
public deletion entry points. `erasure_ctx` is keyed by transaction plus backend; erasure authority derives from a current
job lease/step, never an arbitrary subject argument. Application writes require the exact reviewed erasure shape or ordinary
admission. Auth-gone cascade exemption remains the Q17 table/column state predicate plus trigger nesting, **not** proof of
Auth-call provenance; pending-but-live owners and non-listed tables have no cascade exemption.

Discovery SELECT is a separate, continuously available privilege for code running as the narrow owner, not erasure-only read
access. It covers devices, processed captures, logs (added for historical install ownership), owner history, referrals,
referral codes, retry rows and fingerprints. `using (true)` discovery does not authorize writes. The new processed-capture
column UPDATE and retry/fingerprint DELETE grants are narrowed by erasure policies and exact trigger predicates. Every such
privilege still requires privileged-adoption approval.

E1.3 traverses memberships **from each API principal outward** to reachable roles. PG15 treats membership as SET reach and
uses the member's `rolinherit` for inheritance; PG16+ reads `inherit_option`/`set_option`. Access through `to_jsonb(m)` avoids
referencing absent PG15 option columns. The union of edge types intentionally overapproximates mixed chains; unsupported
chains may refuse adoption. Every reachable role is checked for effective EXECUTE, schema/table/column rights, including
PUBLIC/inherited grants. Principal identity controls exceptions: an authenticated→service_role path is refused, never
exempted by service membership. Reachable superuser/CREATEROLE, narrow-owner or unexpected BYPASSRLS authority is refused.
Any role-admin option held by a reachable role also refuses, including a disabled SET/inherit edge that it could administer.
No role graph is modified and no new API authority is granted. Target-version catalog semantics remain unexecuted and need
Astra review plus separately approved proof, including inheritance-only, SET-only, mixed and disabled-option fixtures.

## E2 / Q13 / Q14 — Operation-by-operation closure draft

The inventory enumerates the 45 named fenced application tables and their I/U/D/TRUNCATE treatment. This is a proposed
source inventory; its earlier retry/log completeness claim was rejected by Astra and is superseded by the contract below. Existing stamped-table I/U
hooks, restrictive authenticated policies, exact erasure/minimisation predicates and RPC admission remain. Direct service
I/U/D is explicitly revoked on rate limits, AI idempotency and now unused direct sync-state writes (0103:44); their legitimate
trigger/DEFINER writers keep row guards. Explicit column I/U/REFERENCES revokes cover every migration-known column of those
three tables. Effective table **and column** assertions inspect the three application tables through every API-reachable
role, so future columns or membership grants refuse instead of silently reopening direct writes.

TRUNCATE is explicitly revoked from PUBLIC, anon, authenticated and service_role on all 45 tables. The same effective role
traversal checks every table for residual TRUNCATE (including inherited/SET paths). Row triggers are not presented as
TRUNCATE admission. All new revokes are **recommended draft deltas, pending explicit owner approval before adoption/application**.
Table ACL comparison permits only the exact direct privilege removals, preserving all other owner/RLS/ACL state. All public
column ACLs are captured for later comparison; replay is limited to the reviewed three direct-DML tables.

Fingerprint INSERT/UPDATE/DELETE now admits OLD/NEW install attribution. Processed captures/logs/retries also guard DELETE;
ordinary retention deletion takes admission and can refuse pending/gone owners. No blanket retention bypass is added.
Erasure explicitly deletes only matching retries on frozen exclusive installs before their subject-owned or exclusive
ownerless parent logs. A targeted parent with a remaining child refuses deletion; ambiguous/shared children block purge.
Fingerprints are deleted only for frozen exclusive installs. The corresponding narrow policies and trigger shapes cover those deletes. Existing audit/history
DELETE controls remain, with ordinary OLD-owner admission added where their I/U guards previously omitted DELETE. Legacy
queue I/U/D admission prevents mutation of immediate-pending owners. These guards do not implement the now-approved E5
scheduled-request disposition documented below.

Q13: retry claim/reclaim is admitted, including bulk claims. A pending owner may abort a mixed bulk mutation; unrelated work
must be retried in a whole-operation retry or separately reviewed caller operation, never through an implicit exception.
The only retry pass-through is unresolved→resolved with changes limited to `resolved_at, updated_at`. It cannot advance/clear
a claim timestamp, reattribute an install/parent or change attempt/payload fields. Sending remains separately admitted.
`capture_sync_list` retains its exact content-removal-only exception (0112:582–621); acknowledgement is still admitted.

### Bounded retry/log correction following Astra D-SQL3 source verdict

The FK is `notification_retry_queue.notification_log_id → notification_logs.id ON DELETE CASCADE`
(0052_notification_logs.sql:175–179). The child install is independent text (:179); log install is nullable text added by
0112_capture_notifications_retention.sql:60–66. Parent uniqueness (:81–83) does **not** establish hash equality. The original
SQL3 guard admitted only child installs; a parent-only pending UUID could escape claims, reparenting and direct I/U/D.
The original parent-only erasure predicate could also delete a foreign-attributed child. Those completeness claims are withdrawn.

Astra's technical design note, relayed by root, was **RATIFIED WITH REQUIRED CHANGES**: acquire every OLD/NEW parent key before
reading/admitting, same keys for all parent log I/U/D including erasure, failed TRY must abort, re-read under supported snapshot
semantics, explicitly admit parent UUID plus parent/child installs, validate OLD/NEW bindings, and keep exact resolution and
specific Auth-cascade predicates. That note authorizes bounded source correction, not retention-policy adoption or execution.

The corrected guarded contract requires an existing parent with non-null install hash equal to the child's install for every
OLD and NEW side of ordinary retry I/U/D. This is **not** a new schema equality constraint and not evidence of exclusive ownership.
Before the first parent read, both parent identities take transaction advisory TRY keys in the dedicated notification-log
namespace. Every log I/U/D acquires its OLD/NEW identity keys before child checks or erasure bypass. Keys persist to transaction
end; any failed TRY raises `55P03` and aborts. No blocking advisory acquisition or locking SELECT is added, so no parent UPDATE
privilege is granted merely for row locking. Parent reads are separate statements after keys; these guards explicitly refuse
isolation other than READ COMMITTED (`0A000`), including ownerless paths where `admit(NULL)` would otherwise skip its isolation
check. Current-version visibility remains an E8 proof requirement, not a semantic result of text checks.

Retry admission explicitly collects both parent UUIDs, both parent install references and both child install references,
admits installs then UUIDs, and never treats equality or later send admission as a replacement. Log UPDATE checks attached
children against both OLD and proposed NEW identity/hash binding, then ordinary admission includes attached child installs and
OLD/NEW log UUID/install. No historical repair exception exists. Parent DELETE with any child still present refuses before any
erasure bypass, requiring the reviewed explicit child-before-parent path. Missing parents and conflicts raise `QD013` with
`fence:retry_attribution`. The exact unresolved→resolved exception is byte-preserved: only `resolved_at, updated_at` may change;
it does not read/admit parent and cannot change binding, claim or attempts. Ordinary claim/reclaim still takes admission.

Discovery includes a retry parent's explicit UUID in its child install's owner set, even for historical conflicting links.
Acceptance and purge worksets include parent and child installs associated with subject UUID/install ownership. Retry links
with absent/null/mismatched parents or foreign parent UUIDs disqualify exclusive evidence for either referenced install.
Workset inclusion is discovery/locking only; it grants no child erasure authority.

Before **any domain erasure**, preflight freezes all targeted/relevant parent identities and re-reads related retries. A
missing/conflicting binding, or a targeted parent's child lacking frozen exclusive evidence and a held exclusive install gate,
blocks the **whole purge**. Matching retry DELETE requires parent/child hash equality, targeted parent UUID/ownerless-exclusive
scope, child frozen exclusivity and held exclusive install gate in all three places: RLS, exact erasure trigger predicate and
DELETE statement. Verification checks parent UUID/install, child install and unresolved invalid bindings on the subject workset.
A parent guard refuses any overlooked surviving child before FK cascade can delete it. No foreign child is deleted solely
because its parent names the subject.

This deliberately leaves historical conflicts and subject-owned logs with shared/unproven retry installs **blocked pending
explicit O4 owner disposition**. It neither silently repairs old hashes nor chooses foreign-child deletion or retention as a
completed deletion policy. The log's Auth FK is **ON DELETE SET NULL** (0052:24), not DELETE CASCADE; retry→log CASCADE does not
imply Auth provenance. Q17's table-specific Auth-gone DELETE predicate is unchanged, with neither log nor retry added to it.
Missing-parent visibility never creates a generic cascade exception. Actual FK/trigger visibility and legitimate retention
cleanup with attached children remain unproven and may fail closed until a separately reviewed caller path handles children.

Required future E8 cases include parent A/X with child Y/B and the inverse; matching ownerless/healthy controls; OLD/NEW
reparenting and install changes; claim/reclaim/I/U/D; parent UUID/hash changes against claims and acceptance in both orders;
failed TRY and whole-mutation retry; READ COMMITTED freshness and REPEATABLE READ/SERIALIZABLE refusal; parent DELETE and actual
Auth SET NULL/child-before-parent paths; conflicting/shared-child purge with zero partial commit; exact resolution on healthy,
pending, mismatched and missing-parent fixtures. Source checks establish none of those PostgreSQL behaviors.


0110_capture_consent_projection.sql:167–169 already rejects changing `capture_devices.install_id_hash`. It is preserved byte
for byte in the historical migration. Multiple install arguments on processed rows refer to separate existing identifiers;
this revision does not claim that a device primary key can change.

## E7/O4 / Q15 / Q16 — Secondary attribution and pending retention policy

Install discovery includes `claimed_user_id`, `owner_uid`, `consent_owner_uid` for captures referring to either the primary
or consumed install, plus linked/consent device owners, log users and retained first-owner history. Ordinary capture I/U/D
admits both OLD and NEW values of **both install references** and all three UUIDs. The consumed hash is never cast to UUID.
Acceptance and purge worksets include each UUID alone and the consumed install associated with a subject-attributed capture.
A directly subject-owned log also contributes its install. Purge takes exclusive install gates before freezing evidence.

An install is exclusive only with trusted, untransitioned first-owner history for the subject, no foreign device/log owner,
no foreign UUID in any processed-capture owner column and no capture bridging it to a distinct consumed/source install.
A distinct consumed hash disqualifies both sides conservatively even when current owners coincide: current linkage cannot
reconstruct history. Evidence is frozen **before** subject fields/history are minimised and is never recomputed from nulls.

Recommended treatment, **pending owner approval**:

- Proven-exclusive install capture rows and fingerprints are deleted. Parent device DELETE remains limited to exclusive
  subject-owned devices; every other subject device is unlinked with the existing exact shapes. Exclusive ownerless logs
  are deleted alongside directly subject-owned logs; attached retries require the separate binding/exclusive-child contract
  above, otherwise the entire purge refuses pending O4.
- Shared/unproven/conflicting captures are retained; only UUID fields exactly equal to the subject become NULL. Foreign
  UUIDs and content remain. `consumed_by_install_hash` becomes NULL only for a frozen proven-exclusive install. Shared or
  unproven hashes and ambiguous content remain until normal expiry. This is disclosed retained attribution/content,
  not complete de-identification and not permission to blanket-delete another owner's row.
- Direct user-keyed counters are erased. Install-keyed counters of proven-exclusive installs are classified as
  **attributable data** and deleted in the recommended draft (Q16); genuinely shared/unproven/unattributed counters retain
  normal expiry. No-UUID schema is not evidence of anonymity. Each supported rate/idempotency key grammar is still exact.

Verification rejects any remaining subject UUID in any capture owner field and any capture still referencing an exclusive
primary/consumed install. Retained shared/unproven hashes/content are explicitly outside that predicate and require the O4
policy decision. This completes the named source paths for review, not a cascade-safety certification.

## E3 / Q12 — Reviewed attributes and surviving rollback evidence

Generated preflight still pins original function bodies, owners and all modeled attributes to migration statements. The
post-restatement header comparison retains the two SQL→PL/pgSQL language exceptions and adds **only** the exact reviewed
audit transition: BEFORE plpgsql INVOKER, volatile, non-strict, parallel unsafe, non-leakproof, cost 100, no SET list;
AFTER the same values except DEFINER and `search_path=pg_catalog, public, pg_temp`. It checks the after catalog fields and
expected complete header text; it does not skip the audit header or weaken other functions' comparisons. `pg_get_functiondef`
formatting, header splitting and exact proconfig representation still require proof. The audit exception remains O5-pending.

Rollback requires its executor to equal the recorded migration principal. Membership supplies snapshot access; inability to
read the protected snapshots refuses. `rb_fn/rb_tbl/rb_misc` are created as that surviving principal with no `SET ROLE` to the
soon-dropped owner. They are protected from API/PUBLIC/narrow-owner access, owner-checked and compared by complete content at
copy time. They are **required surviving evidence**, not disposable copies owned by a `DROP OWNED` casualty. After role/schema
removal the postcondition explicitly requires them to exist; any mismatch raises within the same transaction, rolling back
all removals. Survival and injected-failure transaction atomicity have not been executed.

ACL symmetric difference is `(current EXCEPT desired) UNION ALL (desired EXCEPT current)`, with both operands parenthesised.
Replay covers the two legacy function EXECUTEs, all 45 TRUNCATE table ACLs and the three direct-DML table column ACLs.
It requires each replay object owner to equal the recorded/approved executor. Thus replay acts as the actual owner; a changed
tuple with another grantor refuses (`QD099`). Unknown ownership or grant chains are not silently reconstructed. All public
column ACLs are compared after narrow-owner cleanup, including unexpected changes outside the replay set.

“Exact” remains bounded: function definitions/owners, table owners/RLS flags, default ACL content and no fence residue require
catalog identity; ACLs require default-expanded tuple equivalence (grantee/grantor/privilege/grant option), not NULL-array
identity. `DROP OWNED` removes narrow-owner grants. `ACCESS EXCLUSIVE` on the job table precedes the open-job check; receipt
retention data would be destroyed by rollback. Approved executor privileges, grantor behavior, default ACL semantics,
quiescence and success/failure round trips remain unproven.

## E7/O2/O5/O6 / Q17–Q19 — Preserved boundaries

History minimisation remains only the monotonic transition shape under a held exclusive install gate, not a general history
rewrite. Narrow/unlink calls still use allow-pending install admission and unlink workset verification. A last_seen-only touch
is an ordinary write (Q18); Edge denial propagation remains a later unit. Auth cascade Q17 wording remains state plus nesting.

O5's recommended fixed actor-reason tombstone, actor nulling and subject admin-membership removal remain **pending owner
approval**. The exact tombstone satisfies inspected reason constraints (0083:263–265,324–326; 0089:55–57; 0101:62–64).
Ordinary feature-audit UPDATE/DELETE/TRUNCATE still refuses `P0403`. Retained snapshots, free text and linkable operation/source/
target references are enumerated field-by-field in inventory §F; actor nulling alone is not de-identification. Q19 deliberately
loses non-identifying reason text too and cannot be adopted without O5 approval. Referral/admin owner manifests and exclusive
`assert_gated` remain. Structured denials and their consumer integration requirements remain unchanged.

## E5 owner policy approved — implementation and adoption unproven

The owner approved this draft-only policy on 2026-10-20: quiesce acceptance and worker dispatch/execution of the old
scheduled-deletion route before incompatible adoption. Preserve future, overdue, queued and partially processed evidence.
Never automatically accelerate an existing scheduled request. A legacy request whose destructive processing is verified
not to have started requires a fresh confirmation from its owner for immediate deletion; that owner may withdraw the
unstarted legacy request. If physical Storage erasure has already begun, do not automatically convert it: require a
separate incident/recovery assessment. An uncertain processing state is not evidence that a request is unstarted.
Accepted new immediate jobs remain non-cancellable under the existing immediate-job contract.

This approved policy does not prove worker quiescence or implement conversion/withdrawal. Clearing a profile schedule is
not proof that queued or running work was cancelled; withdrawal cannot reverse completed Storage erasure. Actual transition
mechanics, rollout and recovery need their own reviewed implementation and separately authorized adoption. No server or real
data change is authorized by this draft-only decision.

## D4–D7 — OWNER-APPROVED 2026-10-24 (completion contract; implementation unparsed and unexecuted)

Source of truth: `/Users/luciq/Documents/Codex/beta1-claude-p1/claude-takeover-20261024/DELETION-COMPLETION-CONTRACT.md`
(owner answers given in the Claude session on 2026-10-24; Beta 1 stays blocked on full immediate deletion, D1). This section
records what the SQL draft does for them. It is **not** evidence of execution, and adoption/application still needs the
separate owner approval of a disposable loopback-only stack. No server or real data change is authorized.

- **D4 (OWNER-APPROVED 2026-10-24)** — Apple token encryption key: AES-256-GCM key in an Edge Function secret, ciphertext destroyed
  after verified revocation or at the end of the retry window, no KMS. SQL support only: `deletion_challenge.nonce_hash`
  (64 lower-hex), `account_deletion_issue_challenge`, `account_deletion_read_challenge`, `account_deletion_apple_subject`
  (service role only; read_challenge returns NULL when absent and exactly `nonce_hash`, `expires_at_ms`, `consumed` when found; Apple `sub` from `auth.identities` `provider_id` (read through the `account_fence.auth_apple_subject` shim), falling back to `identity_data->>'sub'`, never email). The
  raw nonce is returned once and never stored. Challenge TTL 5 minutes; at most 3 open challenges per uid (`QD032`).
  The expired-reserved-material sweep in the purge function destroys orphaned ciphertext whose job never committed.
- **D5 (OWNER-APPROVED 2026-10-24)** — the anonymous post-deletion marker (job with uid nulled, scope, receipt, material metadata) is
  kept 14 days after completion, then physically purged by a daily job. `account_deletion_complete_job` caps `retained_until` at
  `completed_at + 14 days` (a shorter `p_receipt_retention_ms` is honoured, longer/NULL is capped/defaulted; the coordinator's
  30-day default is therefore reduced). `account_fence.purge_expired_deletion_records(p_limit)` (bounded, idempotent, never touches
  nonterminal jobs) also removes attempt tombstones older than 14 days and challenges expired more than 1 day ago. Scheduled by a
  `pg_cron`-guarded `cron.schedule` (daily 03:17) and the `account-deletion-worker` Edge Function every 5 minutes through the
  0098 vault + `net.http_post` pattern (new Vault secret `account_deletion_worker_secret`, an OWNER ACTION). Tombstone deletion
  after 14 days re-opens the window in which a very late replay of a fenced attempt could be accepted; that is an accepted
  consequence of D5, not a fence guarantee.
- **D6 (OWNER-APPROVED 2026-10-24)** — the old referral/entitlement protocol is permanently retired; referrals return only through a
  new, reviewed protocol. Every writer restated in section 5 now begins with `raise exception 'feature_retired' using errcode =
  'QD040'` (no admission, lock or read first): `apply_referral_code`, `request_referral_qualification`,
  `qualify_referral_internal`, `ensure_referral_code`, `apply_entitlement_mutation`, `admin_mutate_entitlement`,
  `admin_reject_referral`, `admin_reverse_referral`, `admin_adjust_referral_progress`, `admin_rotate_referral_code`,
  `admin_publish_reward_rule`, `admin_deactivate_reward_rule`. `get_referral_summary` stays a read path but no longer creates a
  code (it reads the active one; null when none). Existing entitlement rows are untouched; `get_entitlement_decision` and
  feature-flag administration are unchanged. Not retired because they cannot be reached once the above refuse (internal, EXECUTE
  revoked from every API role, no entitlement/claim write): `referral_admin_claim` (audit/idempotency row) and the pure
  `generate_referral_code`. The erasure path (`purge_user_data`, `erase_user_data`) is not a referral protocol writer and is unchanged.
- **D7 (OWNER-APPROVED 2026-10-24)** — admin self-deletion is blocked: a row in `public.admin_users` makes both the challenge issuer and
  `account_deletion_accept` raise `QD031` (`admin_self_delete_blocked`) before any insert; admin rights must be removed first. Admin audit
  history is untouched. Because the narrow owner's erasure policy on `admin_users` is false outside an erasure transaction, a new
  READ-ONLY `account_fence_discovery` SELECT policy on `public.admin_users` (`using (true)`) is added; like the other discovery policies it is a
  separate privilege that needs its own approval.

New privileges this section adds for the narrow owner (all removed by rollback's `DROP OWNED`, with ACLs compared against the
snapshot): USAGE on schema `extensions` and EXECUTE on `extensions.gen_random_bytes(integer)` (pgcrypto, as the existing migrations
assume), and the `admin_users` SELECT policy above. There is NO column SELECT on `auth.identities`: the Apple subject is read through the
migration-role-owned `account_fence.auth_apple_subject` shim (see the qualification section; four shims in total after F2).

## Remaining owner decisions — no adoption chosen here

E8: approve an exact disposable project/runtime, cached image IDs, versions, bootstrap/artifact hashes/order, verified-free
ports, task-owned resources, synthetic credentials, no-pull/network rules, phases and teardown. Protect qirsh_beta1_sync_rc5800,
qirsh_proof and frasaaaaa. This unit requests and uses no execution authority; Apple/KMS/native/hosted work is separately gated.

O4/Q16: approve shared/unproven/unattributed retention, the conflicting capture-field/content and retry/log historical-binding/shared-child treatment, conservative handling
of cross-install capture references and attributable classification/deletion of proven-exclusive counters.

O5/Q19: decide every inventory §F row, retained free text/snapshots/linkable identifiers, reason-text loss and the narrow
append-only exception. The draft is not a substitute for those field decisions.

Privileged adoption/Q14: approve all table/column/membership effective privilege deltas, TRUNCATE/direct sync-state revokes,
new discovery reads/erasure column and DELETE grants, narrow ownership, legacy EXECUTE removal, transient CREATE, caller routing,
worker quiescence, rollout order and rollback assumptions. No additional authority is granted merely to make an assertion pass.

## What remains unproven and open for Astra

The SQL has been parsed and executed on the disposable loopback stack (see the qualification section), so syntax and the main lifecycle are
proven there. Still unproven, or proven only on that stack: behavior against production data volumes and the real hosted catalog, the
review fixes F1-F4 (they need a fresh real-DB lifecycle run), retry mixed-batch liveness under production concurrency, cross-install
capture retention, grantor chains of a hosted project, and atomic rollback failure modes. Deno's 154 passing coordinator/adapter/handler tests do not exercise any of those SQL behaviors. The frozen tests and
coordinator remain unchanged. Generator inspection modes preserve hashes and `--check` matches; no `--write` was required.

Astra review questions: Is conservative mixed role-edge overapproximation acceptable for both target versions? Is retaining
ambiguous shared capture content while minimising only subject fields the intended draft pending O4? Is disqualifying every
cross-install capture bridge sufficiently conservative? Does the implemented retry/log protocol satisfy Astra’s technical
design note without weakening the specific Auth cascade contract? Historical retry conflicts/shared-child blocking remains O4. Are the exact before/after audit header representation and the
recorded executor's snapshot-read/owner replay assumptions correct? Qualify those only in the separately approved E8 matrix.
E4/E6/O3 integration, challenge/Apple/KMS dependencies and owner-policy adoption remain open. No readiness claim is made.

## First real-database qualification (loopback stack, 2026-10-24)

Stack: postgres 17.6.1.167, gotrue v2.197.0, postgrest v14.5, storage-api v1.77.5 (see `supabase/tests/account_deletion_fence/loopback_stack/`).
Defects found by the first parse/execution and fixed: `text || "char"` on `pg_default_acl.defaclobjtype` (cast to text, fence.sql and
rollback.sql); `r.strict` record field (renamed `is_strict` in `gen_rpc_bodies.py`); an unparenthesised `CASE ... THEN` inside a PL/pgSQL
`IF ... THEN` condition; schema-qualified `pg_catalog.extract(epoch from ...)` (not valid syntax); two RAISE format strings with a missing
argument; PL/pgSQL record `r` shadowing the SQL alias `r` in the section 10 assertions; `deletion_material.ref` regex `{8,256}` exceeding the
regex repetition limit 255; and grants to the migration role issued before `ALTER ... OWNER`, which the owner change silently discarded.
Header assumption DISPROVEN: the migration role `postgres` has USAGE on schema `auth` and EXECUTE on `auth.uid()` without grant option,
so the narrow owner could not be given them (the grants were no-ops with a WARNING, and every `auth.*` reference from the narrow owner
failed, including Auth's own user insert through the profiles guard). Fix: three read-only SECURITY DEFINER shims
(`account_fence.auth_uid`, `auth_user_exists`, `auth_apple_subject`) that stay owned by the migration role, are executable by the
narrow owner only, and are pinned by a section 10 assertion. PROVEN: the migration role can CREATE ROLE, hold NOLOGIN/NOINHERIT owner
membership during the transaction, use `extensions.gen_random_bytes` grants, and the PostgREST schema list does not expose `account_fence`.

## Opus 5.5 review fixes F1-F4 (2026-10-24)

- **F1 (P1) legacy 30-day worker.** The E5 owner policy requires quiescing worker dispatch and preserving queued/partial evidence. The
  preflight now takes `LOCK TABLE public.account_purge_queue IN EXCLUSIVE MODE` and raises QD096 when the table has any row (legacy work is
  queued or in progress; it needs a separate E5 incident assessment before this migration). Rows are never deleted or converted. Section 11
  unschedules the pg_cron job `purge-scheduled-deletions-job` (0065) after section 0 recorded its schedule, command and active flag in
  `account_fence.rollback_cron_snapshot`; rollback.sql re-schedules it from that record. Profiles with only `delete_scheduled_at` set stay
  untouched and are never accelerated: the user may cancel them or choose immediate deletion with fresh confirmation (allowed by E5).
- **F2 (P1) account_purge_queue.** The table is never erased: it is provably empty at apply (F1) and nothing can enqueue afterwards (job
  unscheduled). Instead of a DELETE grant, `erase_verify` asserts no queue row exists for the subject via the migration-role shim
  `account_fence.legacy_queue_has_uid(uuid)` (fourth shim; section 10 asserts exactly four).
- **F3 (P2) existence oracle.** `guard_owner_columns` refuses (42501, `owner_column_mismatch`) a direct INSERT/UPDATE by role `anon` or
  `authenticated` (role GUC; the function is SECURITY DEFINER) whose strict owner column differs from `account_fence.auth_uid()`, before any
  admission or lock, on the five client-DML tables (profiles, backups, notification_logs, feature_flag_overrides, financial_import_runs).
  Other tables are written for foreign users only by SECURITY DEFINER RPCs, which run with the caller's role GUC, so the check is scoped to avoid
  breaking them. Test: `acl.sql` section 11.
- **F4 (P2) ciphertext on failed jobs (revised after the real-DB run).** The first version disposed the Apple material immediately on a
  terminal failure; the real DB showed a terminally `failed` job then has no exit (accept() returns the open job, the lease worker never
  claims `failed`, and neither `postgres` nor any API role may update `deletion_job`), and an immediate disposal would make a manual retry
  unable to revoke the Apple token. Decision (Opus): `deletion_job.failed_at` is set by `account_deletion_record_failure` on a terminal
  failure and cleared on a retryable one; the committed Apple ciphertext is RETAINED for at most 14 days after `failed_at` (the D5 window)
  and `purge_expired_deletion_records` disposes it only for jobs with `state = 'failed' and failed_at < now() - 14 days` (counter
  `failed_job_material`; the job row stays). The only exit is `account_fence.operator_requeue_failed_job(uuid)` (migration principal only,
  granted with the literal `grant execute ... to postgres` the file already uses, since the preflight pins `current_user = postgres`):
  `not_failed` when the job is missing or not failed; `apple_material_disposed` when `apple_revoke` is not completed and no committed material
  remains (an owner incident, never a silent skip); otherwise the job becomes `retryable` with `failed_at` cleared, attempts and last_code kept.
  `account_fence.operator_failed_jobs()` (same ACL) lists failed jobs (job_id, last_code, completed_steps, attempts, failed_at,
  material_committed) and never returns uid, ciphertext or attempt_id. Tests: `acl.sql` section 13, `concurrency_test.ts` F4 cases. The
  14-day disposal arm is not exercised on the DB (no test-only way to age `failed_at` is provided).
- **Offline checks:** the generator ignores the 0117 migration when reading history (it restates earlier functions) and `--check` asserts
  the migration and rollback copies are identical to the drafts.

## Opus 5.5 re-review of rc2 (2026-10-24)

- **P2-1 (F3 gap):** `guard_owner_columns` now also refuses (42501 `owner_column_mismatch`, before any admission) an anon/authenticated write on
  the five client tables when an optional (`?`) owner column is non-null and differs from `auth.uid()`, and when an `install:` column is set
  while no owner column equals the caller. Client RLS (e.g. `notification_logs_insert_own`: `auth.uid() = user_id`) never admitted a NULL
  or foreign owner, so install-only rows with a NULL user_id are service-side writes only and no legitimate client write changes.
- **P2-2 (blocking, partial deletion):** a legacy enqueue blocked on the preflight's EXCLUSIVE lock could land after commit. `legacy_queue_guard`
  now refuses EVERY insert into `public.account_purge_queue` with QD003 `legacy_route_unavailable`, whatever the caller (service_role included);
  the trigger is renamed `a0_account_fence_a_legacy_queue` so it fires before the admission guard. The QD096 preflight stays.
- **P2-3 (unbounded retryable):** `account_deletion_record_failure` treats a retryable failure as terminal (state `failed`, `failed_at` set, `last_code`
  kept) when the job was accepted more than `c_max_retryable_age` = 72 hours ago. `operator_failed_jobs()` also returns `accepted_at` (still no uid).
- **P2-4 (no exit once material is disposed):** `account_fence.operator_cancel_failed_job(uuid)` (migration principal only, same ownership/search_path/ACL
  pattern, asserted with the other two operator functions). Allowed only for `state = 'failed'` and no completed step; it deletes material, workset,
  scope, receipt and the subject's challenges, tombstones the attempt id (no replay) and deletes the job, so the uid is no longer pending and the user can
  start a fresh deletion with a new Apple re-authentication. Otherwise `{ok:false, reason:'not_cancellable'}`. FKs to `deletion_job` are exactly scope,
  receipt, material and workset.
- **P3-2 (cron snapshot):** the snapshot also records `database` and `username`. Rollback compares a temp copy (`rb_cron`) like the other snapshots, refuses
  (QD099) unless jobname/schedule/command equal the 0065 values (`30 3 * * *`, `select public.run_purge_scheduled_deletions()`), re-schedules with
  `cron.schedule` when database and user match the current ones, with `cron.schedule_in_database` when available otherwise, and refuses (QD099) when neither applies.

