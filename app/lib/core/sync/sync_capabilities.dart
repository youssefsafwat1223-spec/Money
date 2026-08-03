/// MALI-022 / MALI-057n — client sync capability gates.
///
/// A capability describes something the SERVER must support before the client
/// may use it. Each stays OFF until the corresponding server migration is
/// applied AND verified on staging with real Postgres concurrency tests.
library;

/// Whether the server enforces the atomic revision compare-and-set contract
/// from migration 0068 (server-owned `revision` column + `bump_revision`
/// BEFORE UPDATE trigger; see supabase/migrations/0068_entity_revision_cas.sql).
///
/// When true, a conflict-safe update becomes a single atomic statement —
///   `UPDATE <t> SET <patch> WHERE id = :id AND revision = :expected`
/// — and a zero-row result is a typed conflict, not a lost update.
///
/// MUST remain false until 0068 is deployed and verified on staging. Flipping it
/// early would send the server `.eq('revision', …)` predicates against a column
/// it does not have, breaking every guarded update. This is the ONLY switch that
/// activates the client CAS path; the whole plumbing below it is dormant while
/// it is false, and the OFF path keeps using the safest compatible guard (the
/// `server_updated_at` optimistic compare), never a blind overwrite.
///
/// ⚠️ EXTERNAL VERIFICATION PENDING — do not enable in production. Activation is
/// blocked on: (1) `supabase db push` applying 0068 to staging, and (2) the live
/// Postgres concurrency contract tests in supabase/tests/revision_cas_node_test
/// passing against that staging project.
const bool kServerRevisionCas = false;
