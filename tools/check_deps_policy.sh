#!/usr/bin/env bash
# MALI-037 (LOCAL/deterministic part) — dependency-reproducibility & supply-chain
# policy. This is intentionally OFFLINE and network-free so the canonical gate
# stays deterministic: it only reads the committed pubspec.yaml / pubspec.lock.
#
# The NETWORK/EXTERNAL half of MALI-037 (CVE feed, `dart pub outdated` registry
# freshness, ecosystem advisory lookup) is deliberately NOT here — it would make
# the mandatory gate depend on registry availability. It runs out-of-band.
#
# Checks:
#   1. pubspec.lock is present (reproducible resolution artifact).
#   2. No `git:` dependencies (non-reproducible / unpinned supply chain).
#   3. Every path dependency is on the approved allowlist.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBSPEC="$ROOT/app/pubspec.yaml"
LOCK="$ROOT/app/pubspec.lock"
viol=0
fail() { echo "  ✗ $1"; viol=1; }
okc()  { echo "  ✓ $1"; }

# Approved path dependencies (local first-party packages). Add here intentionally.
APPROVED_PATH_DEPS="packages/native_glass_navbar"

echo "══ MALI-037 dependency policy (offline) ══"

# 1. Lockfile present ----------------------------------------------------------
if [ -f "$LOCK" ]; then okc "pubspec.lock present (reproducible resolution)"; else
  fail "app/pubspec.lock missing — commit it for reproducible builds"; fi

# 2. No git dependencies -------------------------------------------------------
git_deps="$(grep -nE '^\s+git:' "$PUBSPEC" 2>/dev/null)"
if [ -z "$git_deps" ]; then okc "no git: dependencies"; else
  fail "git: dependency present (non-reproducible):"; echo "$git_deps"; fi

# 3. Path dependencies on the allowlist ---------------------------------------
#    A path dependency is a `path:` whose value is a filesystem path (contains a
#    '/'); `path: ^1.9.1` (the `path` package version constraint) is not one.
bad_paths=""
while IFS= read -r line; do
  val="$(echo "$line" | sed -E 's/^[[:space:]]*path:[[:space:]]*//')"
  approved=0
  for a in $APPROVED_PATH_DEPS; do [ "$val" = "$a" ] && approved=1; done
  [ "$approved" = 1 ] || bad_paths="$bad_paths\n  $line"
done < <(grep -E '^\s+path:[[:space:]]+\S*/' "$PUBSPEC" 2>/dev/null)
if [ -z "$bad_paths" ]; then okc "path dependencies limited to the allowlist ($APPROVED_PATH_DEPS)"; else
  fail "unapproved path dependency (add to APPROVED_PATH_DEPS if intended):"; printf "%b\n" "$bad_paths"; fi

echo
if [ "$viol" -eq 0 ]; then
  echo "DEPS POLICY PASS — reproducible, no git deps, path deps allowlisted."
  exit 0
else
  echo "DEPS POLICY FAIL — see ✗ above."
  exit 1
fi
