# Deferred migrations

A migration in this directory is **complete, reviewed and deliberately NOT
deployed**. It is held here rather than in `../migrations/` so that
`supabase db push` cannot propose it — a header comment saying "do not apply"
does not stop the CLI, and the whole point of deferring is that the tool must not
offer it.

**This is not an archive of abandoned work.** Everything here is intended to ship
once a specific, named condition is met. Each entry states that condition.

## Rules

- **Only the highest-numbered migration may be deferred.** The lint in
  `../tools/check_migrations.sh` requires the active chain to be gapless, so
  parking a migration from the middle would break it — correctly. If you need to
  defer something that is not last, renumber it to the end first.
- **Move the rollback with it.** Source and reversal stay together so activation
  is one move, not two half-remembered ones.
- A deferred migration is **not** counted by the active lint. That is intended:
  it is not part of the deployment target.

## Reactivating

```bash
git mv supabase/deferred/00NN_name.sql          supabase/migrations/
git mv supabase/deferred/00NN_name_rollback.sql supabase/rollback/
bash supabase/tools/check_migrations.sh          # numbering must stay gapless
supabase db push --dry-run --linked              # must now propose it
```

If a later migration has since taken the number, renumber the deferred one to the
new tail before moving it back.

## Activation set and ordering (renumbered 2026-10-01)

The active chain ends at **0099**. The deferred files are numbered so the
activation set is unambiguous and gapless:

| # | File | State |
|---|------|-------|
| 0100 | `sender_mapping_accepted_by` | activation set, 1st |
| 0101 | `feature_flag_admin_audit` | activation set, 2nd (needs 0100's column for its `ai_sender_mapping_auto` guard) |
| 0102 | `awaiting_fx_transactions` | activation set, 3rd (independent of 0100/0101) |
| 0103 | `record_metric_ad_keys` | **stays deferred** (owner decision + `p_dimension` guard, below) |

Activate **0100, 0101, 0102 in that order** (the chain must stay gapless: 0099 ->
0100 -> 0101 -> 0102). 0103 must NOT be moved while it is blocked, and must never
be activated ahead of 0100-0102. Only the filenames and self-naming header
comments of the files changed in the renumbering; executable SQL is unchanged
except the human-readable text of two RAISE messages that name a migration number.

### PRE-ACTIVATION CHECK (mandatory, before any `db push`)

Production `supabase_migrations.schema_migrations` must contain **none** of
versions `0100`, `0101`, `0102`, `0103` (these numbers previously meant different
files; a recorded version under the old meaning would make the CLI skip or
mis-order the new file). Verify read-only against the linked project:

```sql
select version, name from supabase_migrations.schema_migrations
where version in ('0100','0101','0102','0103');   -- must return 0 rows
```

If any row exists, STOP and reconcile before activating.

---

## 0100_sender_mapping_accepted_by.sql — DEFERRED 2026-09-30

Adds the nullable `sender_bank_mappings.accepted_by` provenance column
(`user` | `ai_validated`; NULL = legacy, treated as user-accepted). Additive,
no RLS change.

**Condition for activation: activate and deploy BEFORE enabling the app-read
flag `ai_sender_mapping_auto`.** The client only writes `accepted_by` for
AI-validated mappings, which only exist while `ai_sender_mapping_auto` is ON;
user confirmations leave it NULL; therefore sync payloads never contain
`accepted_by` while the flag is OFF, and the column is not required until then.

**Activation ordering.** First of the activation set 0100-0102 (see the table
above); the active chain ends at 0099.

---

## 0101_feature_flag_admin_audit.sql — DEFERRED 2026-09-30

WP5-Lite admin feature-flag control plane. Adds the append-only
`feature_flag_admin_audit` table (no actor column on `feature_flags`: it has an
anon SELECT policy), an `updated_at`
trigger on `feature_flags` (reuses `set_updated_at()`), the authorization seam
`admin_can_change_flag(actor, key)` and the service-role-only
`admin_apply_feature_flag_changes(p_actor, p_reason, p_operation_id, p_changes)`
RPC (atomic, row-locked, optimistic on `expected_updated_at`, per-field
validation, idempotent on `operation_id`, blocks enabling
`ai_sender_mapping_auto` while `sender_bank_mappings.accepted_by` is missing).

**Condition for activation: deploy together with the Admin release that ships
`/api/feature-flags`.** Until then the Admin page lists flags read-only (audit
history reports "unavailable") and `/apply` fails closed — the generic
`/api/admin-data` PATCH no longer writes `feature_flags`.

**Ordering.** Second of the activation set, after 0100 (it needs 0100's
`accepted_by` column for its `ai_sender_mapping_auto` guard).

SQL proof: `supabase/tests/feature_flag_admin_audit_0101.sql` (run inside a
rolled-back transaction on a LOCAL Postgres; the header has the command).

---

## 0102_awaiting_fx_transactions.sql — DEFERRED 2026-09-30

A-6 server half. Decision (Astra A2 option A): a confirmed foreign-currency
transaction awaiting FX pricing is stored as `amount = 0` + `foreign_amount > 0` +
`foreign_currency`; no converted amount is ever fabricated. Replaces
`chk_user_transactions_amount_positive` with
`chk_user_transactions_amount_or_awaiting_fx` (negative, or 0 without a foreign
amount, still rejected), makes `category_spending_summary` (the only server
aggregate that counts rows) exclude awaiting rows, and adds the read-only
`qirsh_server_capabilities()` RPC (authenticated only) the app uses as its
explicit capability check. **Every later migration that adds a capability must
`CREATE OR REPLACE` that function with the previous keys plus its own.**

**Condition for activation: deploy BEFORE (or with) the app release that writes
awaiting-FX rows.** Independent of 0100-0101 (no dependency); third of the
activation set (activate after 0100 and 0101).

**Rollback refuses** (RAISE) while any `amount = 0` row exists; the message says
how to resolve (price or delete them).

SQL proof: `supabase/tests/awaiting_fx_0102.sql` (rolled-back transaction on a
LOCAL Postgres; the header has the command).

---

## 0103_record_metric_ad_keys.sql — DEFERRED 2026-09-04 (stays deferred)

> **RENUMBERED 0098 → 0099 → 0100 → 0103** (2026-10-01: the sender-mapping, flag-audit and awaiting-FX migrations take 0100-0102 as the activation set; this one stays deferred behind them).
>
> Earlier: 0098 → 0099 → 0100. Twice now, exactly as the policy above
> anticipates: `migrations/0098_engagement_worker_secret_auth.sql` claimed 0098,
> then `migrations/0099_parser_safety_rule_scoped_evidence.sql` claimed 0099. As
> the policy above anticipates. This file and its rollback were renamed so that
> **no number is ever carried by both an active and a deferred migration** — a
> duplicate would mislead tooling, operators and the release ledger about what
> "0098" means. Only the filenames and their self-naming header comments
> changed; the executable SQL is byte-identical (verified by hashing the
> non-comment body before and after).
>
> If a future migration takes 0103 too, renumber this file again to the new
> tail before moving it back. Reactivating it below the last applied remote
> version would additionally require `--include-all`, which the Supabase CLI
> otherwise refuses.

**Conditions for activation (BOTH required): (1) an explicit owner decision to
switch report-export and banner telemetry ON; (2) the `p_dimension` guard below.**

`0103` adds eleven event keys to `record_metric`'s server-side allowlist, which
0072 ships as `ARRAY['app_open']`.

**There is no telemetry feature flag. That allowlist IS the switch.** Two of the
eleven keys are already emitted by shipped clients:
`report_export_coordinator.dart:82` fires `report_export_requested` at the top of
`run()`, before any ad gate, and `:201` fires `report_export_completed` after
every successful export. Their only gate is cloud-processing consent
(`report_ads_analytics.dart:39`) — **not** `enable_report_ads`.

So applying 0103 would immediately begin persisting report-export telemetry for
every cloud-consenting user, and no feature flag could prevent it. That is
incompatible with the standing requirement that telemetry stay off, so it is
deferred rather than deployed. Deferring is safe: nothing depends on it, and
until it is applied the client's ad-key events are silently dropped by
`record_metric`, exactly as they have been since R4.

**Before activating, fix the finding recorded in
`docs/project/MIGRATION_LEDGER.md`:** `p_dimension` is server-side free text —
the function enforces only `length <= 128` (`0103:72`) while a comment claims the
client can only pass a placement key. A `p_dimension ~ '^[a-z0-9_]{1,32}$'` guard
closes it.
