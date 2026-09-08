#!/bin/zsh
# Guarded wrapper for remote Supabase CLI commands.
#
# WHY: `supabase migration list --linked` was run during QA and resolved to
# vrombzdgwqjjiijbidqb — a ZERO-CONTACT project — because the link in
# supabase/.temp/project-ref points there and nothing checked before executing.
# It was read-only and stopped immediately, but the rule is absolute, so the
# target must be proven BEFORE any remote command, never inferred from a link.
#
#   supabase_safe.sh <ref> <supabase args...>
#
# The ref is explicit and positional: there is no path here that discovers a
# target on its own.
set -u

# Refs that must never be contacted, for any reason, read or write.
FORBIDDEN=(vrombzdgwqjjiijbidqb dpdukyozedajelflkeix bdhqjijscwdzqwqanygv)
# The only refs this repo may talk to. Add one only with owner authorisation.
ALLOWED=(rjwphwsefnuotpbtuycf)

REF="${1:-}"; shift 2>/dev/null || true
if [[ -z "$REF" ]]; then
  print -u2 "refusing: no project ref given. usage: supabase_safe.sh <ref> <args...>"
  exit 2
fi

# --linked is banned outright: it resolves a target from on-disk state that this
# guard cannot vouch for, which is exactly how the incident happened.
for arg in "$@"; do
  if [[ "$arg" == "--linked" ]]; then
    print -u2 "refusing: --linked is banned; pass an explicit ref"
    exit 2
  fi
done

for f in $FORBIDDEN; do
  if [[ "$REF" == "$f" ]]; then
    print -u2 "REFUSING: $REF is a ZERO-CONTACT project"
    exit 3
  fi
done

ok=0
for a in $ALLOWED; do [[ "$REF" == "$a" ]] && ok=1; done
if (( ! ok )); then
  print -u2 "refusing: $REF is not in the allowlist ($ALLOWED)"
  exit 3
fi

# Announce the resolved target before doing anything remote.
print "supabase target ref: $REF"
exec supabase "$@" --project-ref "$REF"
