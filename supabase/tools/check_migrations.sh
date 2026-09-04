#!/usr/bin/env bash
# Static migration / RLS gate (MALI-036). Runs offline (no DB), so CI can catch
# the classes of backend bugs this audit found without a live Postgres:
#   1. Migration numbering — no gaps, no duplicates (a missing/renumbered file
#      silently skips schema on a fresh apply).
#   2. SECURITY DEFINER lockdown — every SECURITY DEFINER function must be
#      revoked from public/anon/authenticated OR be trigger-bound (invoked only
#      by its trigger; a direct call lacks trigger context). An unlocked,
#      client-callable definer function is the MALI-004/005 bug class.
#
# Usage: supabase/tools/check_migrations.sh [migrations-dir]
# Exit 0 = pass; non-zero = a gate violation.
set -euo pipefail

MIG_DIR="${1:-$(dirname "$0")/../migrations}"
fail=0
note() { echo "FAIL: $*" >&2; fail=1; }

[ -d "$MIG_DIR" ] || { echo "migrations dir not found: $MIG_DIR" >&2; exit 2; }
echo "Linting migrations in $MIG_DIR"

# 1) Sequential numbering.
nums=$(for f in "$MIG_DIR"/*.sql; do
  basename "$f" | sed -E 's/^0*([0-9]+)_.*/\1/'
done | sort -n)
prev=0
for n in $nums; do
  if [ "$n" = "$prev" ]; then note "duplicate migration number: $n"; fi
  if [ "$prev" -ne 0 ] && [ "$n" -ne "$((prev + 1))" ]; then
    note "gap in migration numbers: $prev -> $n"
  fi
  prev=$n
done
echo "  numbering: 0001..$(printf '%04d' "$prev") ($(echo "$nums" | wc -w | xargs) files)"

# 2) SECURITY DEFINER lockdown.
sd_funcs=$(for f in "$MIG_DIR"/*.sql; do
  awk '
    tolower($0) ~ /create (or replace )?function/ {
      l=$0; sub(/.*[Ff][Uu][Nn][Cc][Tt][Ii][Oo][Nn][ \t]+/,"",l);
      sub(/\(.*/,"",l); gsub(/public\./,"",l); gsub(/[ \t;]/,"",l); cur=l
    }
    tolower($0) ~ /security definer/ { if (cur!="") { print cur; cur="" } }
  ' "$f"
done | sort -u)

# Lowercase first — BSD sed can't do case-insensitive substitution, and SQL
# keywords appear in both cases across the corpus.
revoked=$(grep -rhoiE "revoke .* on function (public\.)?[a-z_]+" "$MIG_DIR" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/.*function (public\.)?([a-z_]+).*/\2/' | sort -u)
trigger_bound=$(grep -rhoiE "execute (function|procedure) (public\.)?[a-z_]+" "$MIG_DIR" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/.*(function|procedure) (public\.)?([a-z_]+).*/\3/' | sort -u)

for fn in $sd_funcs; do
  if printf '%s\n' "$revoked" | grep -qx "$fn"; then continue; fi
  if printf '%s\n' "$trigger_bound" | grep -qx "$fn"; then continue; fi
  note "SECURITY DEFINER function '$fn' is neither revoked from " \
"public/anon/authenticated nor trigger-bound — a client could invoke it " \
"directly (MALI-004 class). Add: revoke all on function $fn(...) from public, anon, authenticated;"
done
sd_count=$(printf '%s\n' "$sd_funcs" | grep -c . || true)
echo "  SECURITY DEFINER functions checked: $sd_count"

# 3) Rollback coverage. Release prep found migrations 0084-0091 shipped with no
#    entry in supabase/rollback/ at all, while fifteen earlier migrations had
#    one — the convention existed and had quietly stopped being followed. A
#    migration with no documented reversal is one you cannot safely apply to
#    production at 2am.
#
#    Coverage starts at ROLLBACK_FLOOR because the early chain predates the
#    convention; retrofitting reversals for the initial schema would be fiction
#    rather than safety. The floor is a single number so raising it is a visible
#    decision instead of a silent drift.
ROLLBACK_DIR="$(dirname "$0")/../rollback"
ROLLBACK_FLOOR=84
missing_rollback=0
if [ -d "$ROLLBACK_DIR" ]; then
  for f in "$MIG_DIR"/*.sql; do
    base=$(basename "$f" .sql)
    n=$(echo "$base" | sed -E 's/^0*([0-9]+)_.*/\1/')
    [ "$n" -lt "$ROLLBACK_FLOOR" ] && continue
    if [ ! -f "$ROLLBACK_DIR/${base}_rollback.sql" ]; then
      note "migration '$base' has no rollback: expected rollback/${base}_rollback.sql"
      missing_rollback=$((missing_rollback + 1))
    fi
  done
  echo "  rollback coverage from $ROLLBACK_FLOOR: $missing_rollback missing"
else
  note "rollback directory not found: $ROLLBACK_DIR"
fi

# 4) catalog_versions seed floor — the first-row-visibility invariant.
#
#    A migration that CREATEs a versioned catalog table and seeds its
#    catalog_versions row must seed it at 0. Both the version sequence and the
#    seed start the table's life, and the first row inserted takes
#    nextval() = 1. Seeded at 1, that first row's updated_version equals the
#    category version, catalog-delta serves items with
#    `.gt('updated_version', since)` (catalog-delta/index.ts:100), and any device
#    that stored version 1 for the then-empty category never receives it —
#    permanently, with no version change to signal a delta. Row 2 onward arrives
#    normally, so the symptom is a single missing row on some devices only.
#
#    0002 got this right by omitting the column and taking the DEFAULT 0.
#    0094 shipped `('catalog_merchants', 1, ...)` and was caught in review before
#    it was applied. This check exists so the next one is caught by CI instead.
seed_bad=0
for f in "$MIG_DIR"/*.sql; do
  # Only migrations that CREATE a catalog table are in scope; a later migration
  # legitimately bumps an existing category to a nonzero version.
  grep -qiE 'CREATE TABLE[^;]*catalog_' "$f" || continue
  while IFS= read -r line; do
    # Match a seed tuple: ('category', <n>, ...) with a nonzero literal version.
    if printf '%s' "$line" | grep -qE "\('[a-z_]+',[[:space:]]*[1-9][0-9]*[[:space:]]*,"; then
      note "$(basename "$f"): seeds catalog_versions at a nonzero version: ${line# }"
      note "  seed at 0 — see the first-row-visibility invariant in this lint."
      seed_bad=$((seed_bad + 1))
      fail=1
    fi
  done < <(awk '/INSERT INTO catalog_versions/,/;/' "$f")
done
echo "  catalog_versions seed floor: $seed_bad violation(s)"

if [ "$fail" -eq 0 ]; then
  echo "PASS: migrations lint (numbering + SECURITY DEFINER lockdown + rollback coverage + catalog seed floor)."
fi
exit "$fail"
