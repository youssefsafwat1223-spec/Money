# 25 — Disaster Recovery

Related: [26_BACKUP_STRATEGY.md](26_BACKUP_STRATEGY.md), [28_PRODUCTION_RUNBOOK.md](28_PRODUCTION_RUNBOOK.md), [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md) §5.

## 1. Scope

This document covers recovery from severe, unexpected failures — not routine rollback (see [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md) §5 for that). Disaster scenarios covered here: data corruption, a bad migration applied without a working rollback, a compromised credential, and total loss of the Supabase project.

## 2. Scenario: on-device Drift database corruption (single user)

**Symptom**: app shows its own recovery screen ("تعذّر فتح بياناتك") on launch, or crashes attempting to open the database.

**Recovery**:
1. Confirm this is genuinely a corrupted/mismatched-key database, not a transient issue (retry a clean relaunch first).
2. The documented recovery path (matching the in-app "Reset Data" button) is to delete the local `.sqlite`/`-wal`/`-shm` files and relaunch, producing a fresh empty local database.
3. **Data-loss implication**: if the affected user has any Supabase-primary flags OFF for their financial entities, this is a genuine, unrecoverable local data loss for those entities (there is no server copy). If the relevant flags are ON, the next successful resume will re-populate Drift from the Supabase-authoritative data via the routed repository's normal read path — communicate this distinction clearly to the affected user rather than assuming either outcome.
4. Backups (see [26_BACKUP_STRATEGY.md](26_BACKUP_STRATEGY.md)) are the only recovery path for a user whose local-only data was lost and who does not have Supabase-primary enabled — if they never took a backup, the data is genuinely gone.

## 3. Scenario: a bad migration applied to the live project with a broken/incomplete rollback

**Recovery**:
1. **Stop.** Do not attempt further schema changes to "work around" the bad state.
2. Assess actual damage via the verification queries in [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) — row counts, constraint shapes, whether any real data was actually altered/lost or only a constraint/index is in a bad state.
3. If the rollback file is broken (e.g., it assumes a data shape that no longer holds because new data has since been written under the new constraint), write a **new**, corrective migration rather than forcing the original rollback to run — treat it as a fresh, carefully-verified change, following the full migration checklist in [01_GLOBAL_RULES.md](01_GLOBAL_RULES.md) Rule 8.
4. Report the exact state and proposed corrective migration for explicit approval before applying anything — a disaster-recovery migration is exactly the kind of destructive-adjacent action requiring sign-off per [00_SYSTEM_PROMPT.md](00_SYSTEM_PROMPT.md) §8.

## 4. Scenario: compromised device secret or service-role key

**Device secret** (single device/user impact):
1. The affected `capture_devices` row's `device_secret_hash` can be invalidated (e.g., by deleting the row, forcing re-registration) — the blast radius is limited to that one device's capture-relay access, which itself has no write access beyond the deny-all-RLS capture tables and (if direct-write is enabled for that user) that single user's own `user_transactions` rows.
2. Notify the affected user to re-run onboarding's capture setup to re-register.

**Service-role key** (project-wide impact — treat as critical):
1. Rotate the key immediately via the Supabase Dashboard (Project Settings → API).
2. Redeploy every Edge Function so they pick up the new key from environment variables (Edge Functions read it fresh from `Deno.env.get(...)` per invocation — no code change needed, but a redeploy ensures no cached process is using a stale one, if applicable to the runtime's behavior).
3. Audit Postgres/Edge Function logs for the compromise window for any anomalous activity across **all** RLS-scoped and deny-all tables, not just the capture tables — a leaked service-role key bypasses every RLS policy in the project.
4. This is a full incident — document what happened, when, how it was discovered, and what was done, even after the immediate rotation, per the spirit of [17_BUG_WORKFLOW.md](17_BUG_WORKFLOW.md) §7's report format adapted for a security incident rather than a bug.

## 5. Scenario: total loss/inaccessibility of the Supabase project

This is the most severe scenario covered here. Recovery depends entirely on what backup/export capability actually exists at the time (Supabase's own project-level backups, if enabled on the plan, plus whatever `backups` Storage-bucket exports individual users have taken — see [26_BACKUP_STRATEGY.md](26_BACKUP_STRATEGY.md)).

1. Confirm the actual scope of loss (is the project truly gone, or is this a transient outage — check Supabase's own status page first).
2. If catalog data is lost, it can be substantially reconstructed from the migration files (`supabase/migrations/*.sql` define the schema; seed data for banks/parsers/categories may need to be re-derived from whatever seed scripts or the last-known-good export exists).
3. If financial data (`user_*` tables) is lost for users who had a Supabase-primary flag ON, **their Drift mirror (if not itself also lost/stale) is the only remaining copy** — this is precisely why the mirror-write mechanism in [03_ARCHITECTURE.md](03_ARCHITECTURE.md) §4 exists, and why disabling Supabase-primary flags in a genuine emergency (falling back to Drift-as-authoritative) is a legitimate, fast mitigation while the backend is being restored.
4. This scenario has no fully rehearsed runbook in this project's current state — treat any real occurrence as requiring immediate, careful, human-led incident response rather than automated recovery, and use this document's structure as a starting checklist, not a complete playbook.

## 6. General disaster-recovery principles for this project

- **The flag-gated architecture is itself a disaster-recovery mechanism**: falling back from Supabase-primary to Drift-primary for an entity type is fast (a flag flip) and always available as a mitigation, precisely because the migration was built to be reversible per-entity, per-user (see [03_ARCHITECTURE.md](03_ARCHITECTURE.md) §4, [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md) §5). Reach for this lever early in any live incident affecting Supabase-primary users.
- **Never attempt a destructive recovery action without first reading the current state carefully** — a disaster is exactly the situation where panic-driven action (a hasty `DELETE`, a hasty rollback of the wrong migration) causes more damage than the original incident.
- **Prefer additive corrective migrations over forcing a stale rollback** when the two disagree about current data shape (§3).
