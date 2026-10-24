#!/usr/bin/env bash
# Hermetic tests for the SECURITY DEFINER lockdown in check_migrations.sh.
# Builds throwaway migration dirs; touches no database and no network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/check_migrations.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cmt.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
bad=0

# run_case <name> <expect-fail-substr|-> <expect-pass-substr|-> ; SQL on stdin
# Asserts: the SECURITY DEFINER FAIL lines mention every "fail" name and none of
# the "pass" names. $FAILS / $PASSES are space-separated function names.
run_case() {
  local name="$1" d="$ROOT/$1"
  mkdir -p "$d"; cat > "$d/0001_t.sql"
  local out; out=$(bash "$GATE" "$d" 2>&1 | grep "SECURITY DEFINER function" || true)
  local fn ok=1
  for fn in $FAILS; do
    printf '%s\n' "$out" | grep -q "function '$fn'" || { echo "  expected FAIL for $fn"; ok=0; }
  done
  for fn in $PASSES; do
    printf '%s\n' "$out" | grep -q "function '$fn'" && { echo "  unexpected FAIL for $fn"; ok=0; }
  done
  if [ $ok = 1 ]; then echo "ok   $name"; else echo "FAIL $name"; printf '%s\n' "$out"; bad=1; fi
}

FAILS="s.f" PASSES="" run_case qualified_no_revoke <<'SQL'
create function s.f() returns void language sql security definer as $$ select 1 $$;
SQL

FAILS="g" PASSES="" run_case revoked_only_from_anon <<'SQL'
create function g() returns void language sql security definer as $$ select 1 $$;
revoke all on function g() from anon;
SQL

FAILS="h" PASSES="" run_case revoked_only_from_authenticated <<'SQL'
create function h() returns void language sql security definer as $$ select 1 $$;
revoke execute on function public.h() from authenticated;
SQL

FAILS="" PASSES="s.f g" run_case qualified_and_public_revoke <<'SQL'
create function s.f(uuid) returns void language sql security definer as $$ select 1 $$;
create function public.g() returns void language sql security definer as $$ select 1 $$;
REVOKE ALL ON FUNCTION s.f(uuid) FROM PUBLIC, anon, authenticated;
revoke execute on function g() from public;
SQL

FAILS="unlisted" PASSES="a s.b c" run_case multiline_list <<'SQL'
create function public.a(text, uuid) returns void language sql security definer as $$ select 1 $$;
create function s.b(uuid, uuid, integer) returns void language sql security definer as $$ select 1 $$;
create function c(numeric(10,2)) returns void language sql security definer as $$ select 1 $$;
create function unlisted() returns void language sql security definer as $$ select 1 $$;
revoke all on function
  public.a(text, uuid),   -- trailing comment
  s.b(uuid, uuid, integer),
  c(numeric(10,2))
  from public, anon, authenticated, service_role;
SQL

FAILS="k" PASSES="" run_case grant_option_for_is_not_a_revoke <<'SQL'
create function k() returns void language sql security definer as $$ select 1 $$;
revoke grant option for execute on function k() from public, anon, authenticated;
SQL

FAILS="" PASSES="s.t" run_case qualified_trigger_bound <<'SQL'
create function s.t() returns trigger language plpgsql security definer as $$ begin return new; end $$;
create trigger x before insert on y for each row execute function s.t();
SQL

[ $bad = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
