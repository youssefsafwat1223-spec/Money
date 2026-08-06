# Phase 6 — Database, Backup & Restore (local closure)

Status: **Code complete — locally verified; physical-device, native SQLCipher /
process timing, live Supabase, and multi-device verification pending.**

This document is the single reference for the Phase-6 data-integrity/reliability
work (MALI-014, 027 lifecycle tail, 058n, 069n, 076n). It reflects the accepted
contracts through Batch-5 closure. It intentionally does NOT claim device or live
verification — see `PHASE_6_EXTERNAL_VERIFICATION_CHECKLIST.md`.

## 1. Key hierarchy & location contract

- **SQLCipher DB key** — random, stored ONLY in `flutter_secure_storage`
  (Keychain/Keystore). Never in a table, backup, export, log, or the network.
  `user_settings.db_encryption_key_ref` is a deprecated column, always written `''`
  on restore and never carries key material (MALI-058n).
- **Backup content key (v3)** — random per-enable; wrapped by password + recovery
  slots (Argon2id/AES-GCM). Stored locally so background backups need no passphrase.
- **Admission owner identity** — `local_data_owner_uid` + rotating
  `local_data_owner_generation` (Phase-2), in secure storage, read cross-isolate.
- Restore NEVER changes the destination SQLCipher key.

## 2. Backup envelope

- **v3 (current, only written)** — magic `MALIBAK`; header (versions, cipher
  `aes-256-gcm`, kdf `argon2id` + params, compression) bound as AES-GCM **AAD** to
  the payload and every key slot; content key + password/recovery slots.
- **v1/v2 (read-only)** — legacy passphrase/slot formats; still decryptable.
- **Resource limits** (`BackupEnvelopeLimits`) enforced BEFORE the KDF (memory
  8–256 MiB, iters 1–10, parallelism 1–4, salt 16–64B, nonce 12B, ciphertext ≤64
  MiB, ≤8 slots, blob ≤96 MiB).
- **Typed errors** `BackupEnvelopeErrorKind`: unsupportedVersion / malformed /
  unsupportedAlgorithm / unsafeKdfParams / payloadTooLarge / authenticationFailed /
  incompatibleSchema / decodeFailed. Wrong passphrase / tamper / corruption are
  indistinguishable (one message).

## 3. Passphrase semantics

- v3: exact UTF-8, **no trim / no normalization**; case & whitespace significant.
- Legacy: historical trim preserved for old-backup restore.

## 4. Remote backup model (unchanged in Batch 5)

Generation-based: unique per-generation object path, size-verified upload, server
compare-and-set pointer commit (`commit_backup_generation`, SECURITY DEFINER), retain
current + one previous, prune 2-back after commit, verified download (size + encrypted
SHA-256 before decryption), lost-response idempotency. Only `enabledIdle` is
"Protected". Migration **0076** (undeployed).

## 5. DB lifecycle & Contract-B process invariant (MALI-069n / 027)

- Exactly **one OS process** (the Flutter host app) opens the encrypted DB; every
  separate-process target (iOS Share extension, App Intents, Android receivers) is
  pure-native and stages to the App Group / SharedPreferences (proven +
  source-scan-enforced; see `PROCESS_ACCESS_INVENTORY.md`).
- Failed-init closes the connection/isolate (no leak, original error preserved);
  the migration pipeline is the sole `user_version` owner and runs once; secondary
  connections use `openSecondary` (no concurrent migrations); typed
  SQLITE_BUSY/LOCKED; centralized `busy_timeout=5000`.
- **Liveness authority is a process-lifetime OS advisory lock**, NOT heartbeat/mtime.
  Runtime maintenance NEVER reaps: it waits for holders to release with a typed
  bounded timeout (uncertain/blocked ⇒ timeout, never destructive reaping). The only
  reaping is process-start recovery keyed by the random **instance token** (not PID).
  Records are immutable + atomically published.
- **Admission generation**: a background job binds `{ownerUid, generation}` and
  re-validates at 5 boundaries; a sign-out / wipe / ownership change / same-UID
  re-login aborts before commit/ack/notify.

## 6. Maintenance protocol (the restore primitive)

`runFileExclusiveMaintenance` enters its callback only after: admission valid → new
borrows blocked → intent fenced → main borrows drained → new secondaries blocked →
every shared lease released (or, only at startup, its owner proven ended) →
uncertain holders yield a typed timeout → stable-zero verified. Destructive restore
uses this primitive.

## 7. Restore preparation / mutation ordering

**Preparation (no mutation):** verified download → envelope decode/decrypt/limits →
validate schema/whitelist/sensitive-field/required-tables → **per-version adapter**
(v1/v2/v3) normalizes to the current plan → immutable `RestorePlan` (opaque op id,
envelope+schema version, source fingerprint, whitelisted payloads, expected counts,
warnings; no secret/key/path).

**Mutation (consumes only the plan):** revalidate admission → `runFileExclusiveMaintenance`
→ one transaction: FK-safe delete/insert/sanitize → **in-transaction verification**
(singleton + default account, transactions count == plan, no duplicate ids,
sanitize-safe tables ≤ plan, per-currency canonical net-expense total == plan, no
SQLCipher key ref, no excluded/remote table) → durable `committed` journal marker
(same transaction) → commit → acknowledge. Any failure throws before commit → whole
restore rolls back, original DB preserved.

## 8. Restore journal schema & state machine (schema v28)

Table `restore_operations` (additive, version-owned; excluded from
backup/restore/sync/export; wiped on sign-out; bounded retention). Columns:
`operation_id (PK)`, `source_fingerprint`, `envelope_version`,
`snapshot_schema_version`, `owner_generation_hash` (opaque), `state`, `prepared_at`,
`committed_at`, `acknowledged_at`, `terminal_error_class`. No financial/secret data.

States: `prepared → mutating → committed → acknowledged`; failure branches
`failedBeforeMutation`, `rolledBack`, `recoveryRequired`. The `committed` transition
is atomic with the restored data. A restart discovers a committed-but-unacknowledged
operation (`committedPendingAcknowledgement`) and NEVER destructively replays; the
same op id with a different fingerprint is rejected.

## 9. Compatibility matrix

| Envelope | Snapshot schema | Support | Adapter action |
|---|---|---|---|
| v3 | 3 (current) | full | identity |
| v3 | supported older | transformed | per-version required tables + defaults + warning |
| v1 | 1 (legacy) | restore-only | required: user_settings; pre-accounts (default account ensured); `legacy_schema_v1` |
| v2 | 2 (legacy) | restore-only | required: accounts+user_settings; cards/sender-mappings optional; `legacy_schema_v2` |
| unknown future envelope | any | reject before mutation | — |
| known envelope | future schema | reject before mutation | — |
| malformed / unauthenticated | any | reject before mutation | — |

Mali's local restorable column set is uniform across snapshot versions (the manual
schema predates versioned snapshots — same reason `_versionedMigrations` is empty),
so adapters normalize table presence + defaults + warnings, not field renames.
Destination DB migrations and backup-data adapters are separate concerns. Every
supported adapter has a synthetic fixture + end-to-end restore test.

## 10. Rollback & crash matrix

- **Rollback:** faults injected at 9 transaction-boundary points; each proves a
  full-DB digest (all user-data tables) + per-currency totals unchanged and no
  committed marker.
- **Crash-before-commit:** file-backed → reopen = complete old state, no marker,
  FK-clean.
- **Commit-before-ack restart:** discovered via the durable journal, not replayed,
  then acknowledged idempotently.
- **Real `Process.start` native-sqlite kill:** SQLite rolls back the uncommitted
  transaction (native SQLCipher timing external, skip-safe).

## 11. UI confirmation flow

`RestoreController` state machine: downloading → decrypting → validating →
**readyForConfirmation** → waitingForDatabase → restoring → completed / cancelled /
failedWithoutChanges / recoveryRequired. The production restore screen drives it:
preparation runs with NO mutation, an explicit confirmation dialog appears before any
destructive write, cancellation changes nothing, and `completed` is shown only after a
committed outcome. Acknowledgement is idempotent. (Widget-tested.)

## 12. Privacy guarantees

No passphrase, derived key, SQLCipher key, absolute path, financial value, or owner
UID appears in: envelope/preparation errors, journal records, migration errors,
maintenance failures, crash diagnostics, UI state, telemetry, logs, or filenames. Raw
Drift/SQLite/SQLCipher/Supabase/file/crypto errors are never surfaced.

## 13. Migration inventory

- **Local Drift schema:** v27 → **v28** (additive `restore_operations`), owned by the
  versioned migration pipeline (created in `_createSchema`, `user_version` stamped
  last inside the migration transaction). No money-precision or unrelated-table
  changes.
- **Supabase:** 0068–0076 remain **undeployed**; migration **0070** inactive;
  `kServerRevisionCas = false`.

## 14. Known limitations

- Device/native/live-Supabase/multi-device verification is external (see the
  checklist).
- The real `Process.start` native-kill test is skip-safe under load.
- Broad restore-screen visual redesign was intentionally NOT done.
- Pre-existing, unrelated admin `parser-test` quote-mismatch failure (1) is tracked
  for a later test-hygiene phase — NOT a Phase-6 defect.

## 15. External gates

See `PHASE_6_EXTERNAL_VERIFICATION_CHECKLIST.md`.
