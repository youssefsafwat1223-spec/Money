#!/usr/bin/env bash
# MALI-034 architecture guard — a NARROW, code-only invariant check that the
# retired Supabase-primary financial authority cannot silently return.
#
# It is deliberately scoped to CODE signals (imports, quoted flag keys,
# constructor/class usage, the schema constant) so the intentional HISTORY
# comments that name the retired classes ("replaces the retired
# FinancialCacheRepairService cycle", "extracted from SupabaseTransactionRepository")
# do NOT trip it. Each check prints its result; any violation exits non-zero and
# lists the offending lines.
#
# Guards (all against app/lib — production code only):
#   1. DB schema stays at 29 (_targetSchemaVersion). Batch-3 must not bump schema.
#   2. No *_supabase_primary authority-switch flag keys are read (quoted selectors).
#   3. No FinancialCacheRepairService is imported or constructed.
#   4. No legacy Supabase financial repository is imported or constructed.
#   5. No vestigial Routed* repository wrapper is (re)introduced.
#   6. No Drift multiple-database warning suppression (MALI-040) exists in lib OR
#      test — ownership is correct, so the warning must never be masked.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/app/lib"
viol=0

fail() { echo "  ✗ $1"; viol=1; }
okc()  { echo "  ✓ $1"; }

# Grep helper: prints matches, returns 0 if ANY match (i.e. a violation exists).
hits() { grep -rnE "$1" "$LIB" 2>/dev/null; }

echo "══ MALI-034 architecture guard ══"

# 1. Schema pinned at 30 (Phase-8 B8-3 fixed-precision cutover) ----------------
schema_line="$(grep -E 'const int _targetSchemaVersion = [0-9]+;' "$LIB/data/db/app_database.dart" 2>/dev/null)"
if echo "$schema_line" | grep -qE '= 30;'; then
  okc "schema pinned at 30"
else
  fail "schema is not 30 (found: ${schema_line:-<missing>}) — B8-3 is the authorized v30 cutover"
fi

# 2. No *_supabase_primary flag SELECTORS (quoted keys are code; comments aren't) --
m="$(hits "['\"][a-z_]*_supabase_primary['\"]")"
if [ -z "$m" ]; then okc "no *_supabase_primary flag selectors"; else
  fail "*_supabase_primary flag selector present:"; echo "$m"; fi

# 3. No FinancialCacheRepairService import or construction ----------------------
m="$(hits "import .*financial_cache_repair_service\.dart|\bFinancialCacheRepairService\s*\(")"
if [ -z "$m" ]; then okc "no FinancialCacheRepairService wiring"; else
  fail "FinancialCacheRepairService is imported/constructed:"; echo "$m"; fi

# 4. No legacy Supabase financial repository import or construction -------------
m="$(hits "import .*repositories/supabase_[a-z_]+_repository\.dart|\bSupabase(Account|Transaction|Budget|Goal|Bill|Plan|SmartInbox|Category)Repository\s*\(")"
if [ -z "$m" ]; then okc "no legacy Supabase financial repo wiring"; else
  fail "legacy Supabase financial repository imported/constructed:"; echo "$m"; fi

# 5. No vestigial Routed* repository wrapper -----------------------------------
m="$(hits "import .*repositories/routed_[a-z_]+_repository\.dart|\bclass Routed[A-Z][A-Za-z]*Repository\b|\bRouted(Account|Transaction|Budget|Goal|Bill|Plan|SmartInbox|Category)Repository\s*\(")"
if [ -z "$m" ]; then okc "no vestigial Routed* repository wrappers"; else
  fail "Routed* repository wrapper present:"; echo "$m"; fi

# 6. MALI-040 — no Drift multiple-database warning SUPPRESSION anywhere ---------
#    (production OR tests). AppDatabase.close() completes Drift's teardown
#    (super.close() disposes streamQueries + decrements the open-db counter), so
#    the "multiple databases" warning now means a genuine CONCURRENT instance,
#    not ambient noise. Suppressing it globally would re-hide an ownership
#    regression; the correct response to a real warning is to fix ownership.
m="$(grep -rnE 'dontWarnAboutMultipleDatabases' "$ROOT/app/lib" "$ROOT/app/test" 2>/dev/null)"
if [ -z "$m" ]; then okc "no Drift multi-db warning suppression (MALI-040)"; else
  fail "dontWarnAboutMultipleDatabases suppression present (MALI-040):"; echo "$m"; fi

echo
if [ "$viol" -eq 0 ]; then
  echo "ARCH GUARD PASS — Supabase-primary authority stays retired; DB warning suppression stays out."
  exit 0
else
  echo "ARCH GUARD FAIL — a retired-architecture or suppression signal reappeared (see ✗ above)."
  exit 1
fi
