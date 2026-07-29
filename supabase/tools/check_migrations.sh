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

if [ "$fail" -eq 0 ]; then
  echo "PASS: migrations lint (numbering + SECURITY DEFINER lockdown)."
fi
exit "$fail"
