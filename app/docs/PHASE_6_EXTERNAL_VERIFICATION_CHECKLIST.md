# Phase 6 — External Verification Checklist

Everything below is **pending** — it cannot be verified in the local Dart/CI
environment and must be run on real devices / a live backend before Phase 6 can be
called anything beyond "code complete — locally verified." Nothing here is complete.

Each row: **prerequisite · steps · expected · evidence · rollback · owner/status**.

## A. iOS physical device

| Check | Prereq | Steps | Expected | Evidence | Rollback | Status |
|---|---|---|---|---|---|---|
| Keychain key availability + missing-key recovery | paid Apple dev account, App Groups | fresh install → create data → force-quit → relaunch | DB opens with the stored key; a deleted key surfaces the typed recovery state, no crash/corruption | screen recording + Console logs | reinstall | pending |
| SQLCipher open/reopen | device build | open app, background, reopen | encrypted DB opens/reopens; no plaintext file | file inspection via container | — | pending |
| Background isolate capture/notification actions | notifications allowed | receive a captured message + tap a notification action | secondary connection opens under the lease; no corruption; action applies once | logs + DB state | — | pending |
| App Group staging during DB maintenance | Share extension installed | trigger a restore while a Share write is staged | staging is App-Group-only; restore holds the file-exclusive gate; no DB open from the extension | logs | — | pending |
| Restore confirmation UI | committed remote backup | run a restore | explicit confirmation before mutation; truthful phases; success only after reopen | recording | — | pending |
| v3 backup round-trip | Supabase configured | enable → backup → wipe → restore | data restored; totals match | before/after export | — | pending |
| Commit-before-ack restart | — | kill app immediately after a restore commits | relaunch discovers the committed op, no replay, acknowledges | logs | — | pending |
| Lock-screen / privacy | biometric lock on | lock during maintenance | no leakage; maintenance safe | recording | — | pending |

## B. Android physical device

| Check | Prereq | Steps | Expected | Evidence | Rollback | Status |
|---|---|---|---|---|---|---|
| Keystore behavior | device build | fresh install → data → relaunch | key from Keystore; DB opens | logs | reinstall | pending |
| SQLCipher open/reopen | — | open/background/reopen | opens/reopens; no plaintext | file inspection | — | pending |
| Background receiver/isolate | notifications allowed | notification action while app dead | app process starts, secondary connection under lease, single apply | logs | — | pending |
| Auto-backup disabled | — | inspect OS backup | `allowBackup=false` honored (Keystore-bound data not backed up) | adb backup attempt | — | pending |
| Secondary connection contention | — | capture-import during a restore | maintenance drains/refuses secondaries; typed timeout, never reap | logs | — | pending |
| Restore confirmation UI | committed backup | restore | confirmation gate; truthful phases | recording | — | pending |
| v3 round-trip | Supabase configured | enable → backup → wipe → restore | restored; totals match | export | — | pending |
| Process restart behavior | — | kill mid/after restore | crash-before-commit = old state; commit-before-ack = discovered, no replay | logs | — | pending |

## C. Live Supabase

| Check | Prereq | Steps | Expected | Evidence | Rollback | Status |
|---|---|---|---|---|---|---|
| Deploy 0068–0076 in order | staging project | `supabase db push` | all apply cleanly, in order | migration log | `supabase db reset` on staging | pending |
| Backup Storage ownership/RLS | bucket `backups` | attempt cross-user read | denied by RLS | request logs | — | pending |
| Generation CAS | 0076 deployed | concurrent commits | one wins; stale rejected; idempotent replay | RPC logs | — | pending |
| Lost-response replay | — | retry same op | no duplicate generation | rows | — | pending |
| Retention/pruning | — | multiple backups | current + previous kept; 2-back pruned; orphans cleaned | object listing | — | pending |
| Account purge | — | delete account | remote backups removed | listing | — | pending |
| AI consent under 0071 | 0071 deployed | toggle consent | server honors consent for engagement/AI | function logs | — | pending |
| APNs / live notification (Phase 5) | APNs configured | send a push | delivered; verified-identity/consent honored | device | — | pending |

## D. Two-device

| Check | Prereq | Steps | Expected | Evidence | Rollback | Status |
|---|---|---|---|---|---|---|
| Backup stale-generation conflict | 2 devices, 1 account | both back up near-simultaneously | CAS: one wins, other retries; no lost backup | RPC logs | — | pending |
| Sync revision while CAS disabled | `kServerRevisionCas=false` | edit on both | last-writer per current policy; no revision CAS path active | rows | — | pending |
| Ownership isolation | 2 accounts, 1 device | A signs out, B signs in | B never sees A's data; A's background jobs rejected | DB state | — | pending |
| Fallback timing | — | offline then online | bounded retry; truthful state | logs | — | pending |

## Notes

- Do **not** deploy 0068–0076 to production from this checklist; staging only, and
  only when a human owner runs it.
- `kServerRevisionCas` stays `false` and migration **0070** stays inactive until an
  explicit, separately-approved rollout.
