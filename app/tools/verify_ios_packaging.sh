#!/usr/bin/env bash
# iOS packaging regression guard (MALI-020 / release-closure).
#
# Inspects a BUILT Runner.app and asserts the shipping extension inventory,
# privacy-manifest packaging, executables, and bundle identifiers — things unit
# tests cannot see because they concern the final .app/.appex bundles.
#
# Usage: tools/verify_ios_packaging.sh [path/to/Runner.app] [provenance-sidecar]
# Default path: build/ios/iphonesimulator/Runner.app
#
# PROVENANCE GATE (MALI-043 closure): a built bundle is only CURRENT evidence if
# it was stamped (tools/stamp_ios_provenance.sh) from the SAME iOS source tree
# that exists now. A bundle with no `.provenance` sidecar, or one whose recorded
# ios_input_sha differs from the current source, is STALE/UNKNOWN — this script
# then exits 3 ("not current") so the caller reports external/pending, NOT a pass.
#
# Exit codes:
#   0 = provenance CURRENT and all structural checks pass (current evidence)
#   1 = provenance current but a structural packaging regression exists
#   3 = artifact NOT CURRENT (missing/stale provenance) — not a pass, not a regression
set -euo pipefail

APP="${1:-build/ios/iphonesimulator/Runner.app}"
PROVENANCE="${2:-$APP.provenance}"
MAIN_BUNDLE_ID="com.youssefsafwat.mali"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Exactly these extensions must ship (space-separated; macOS bash 3.2 has no
# associative arrays, so ids are resolved via expected_id_for below).
EXPECTED_EXTS="ShareBankMessage.appex"
# Extensions that must NEVER be embedded (obsolete / superseded by in-app code).
FORBIDDEN_EXTS="BankMessageShortcuts.appex"

expected_id_for() {
  case "$1" in
    ShareBankMessage.appex) echo "com.youssefsafwat.mali.ShareBankMessage" ;;
    *) echo "" ;;
  esac
}

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ✓ $*"; }

[ -d "$APP" ] || fail "app bundle not found: $APP (build it first)"
echo "Inspecting $APP"

# --- Provenance gate: is this bundle CURRENT? ------------------------------------
SIDE="$PROVENANCE"
CUR_SHA="$(bash "$REPO_ROOT/tools/ios_input_sha.sh")"
if [ ! -f "$SIDE" ]; then
  echo "NOT CURRENT: no provenance sidecar ($SIDE). This bundle's origin is" >&2
  echo "unknown/stale; build fresh + tools/stamp_ios_provenance.sh to make it" >&2
  echo "current evidence. (current ios_input_sha=$CUR_SHA)" >&2
  exit 3
fi
REC_SHA="$(grep '^ios_input_sha=' "$SIDE" | cut -d= -f2 || true)"
if [ "$REC_SHA" != "$CUR_SHA" ]; then
  echo "NOT CURRENT: artifact provenance ios_input_sha=$REC_SHA" >&2
  echo "!= current iOS source ios_input_sha=$CUR_SHA — the bundle predates the" >&2
  echo "current iOS sources (rebuild + re-stamp to refresh)." >&2
  exit 3
fi
ok "provenance CURRENT (ios_input_sha=$CUR_SHA)"

bundle_id() { plutil -extract CFBundleIdentifier raw -o - "$1/Info.plist" 2>/dev/null || true; }
bundle_exe() { plutil -extract CFBundleExecutable raw -o - "$1/Info.plist" 2>/dev/null || true; }

# 1) Main app: manifest + correct bundle id + Mach-O executable.
[ -f "$APP/PrivacyInfo.xcprivacy" ] || fail "main app missing PrivacyInfo.xcprivacy"
ok "main app PrivacyInfo.xcprivacy present"
mid="$(bundle_id "$APP")"
[ "$mid" = "$MAIN_BUNDLE_ID" ] || fail "main bundle id '$mid' != '$MAIN_BUNDLE_ID'"
ok "main bundle id $mid"
mexe="$(bundle_exe "$APP")"
file "$APP/$mexe" | grep -q "Mach-O" || fail "main executable missing/not Mach-O: $mexe"
ok "main executable $mexe is Mach-O"

# 2) Enumerate embedded extensions.
PLUGINS="$APP/PlugIns"
FOUND_EXTS=""
if [ -d "$PLUGINS" ]; then
  while IFS= read -r ext; do FOUND_EXTS="$FOUND_EXTS $(basename "$ext")"; done \
    < <(find "$PLUGINS" -maxdepth 1 -name "*.appex" | sort)
fi
FOUND_EXTS="$(echo "$FOUND_EXTS" | xargs)" # trim
echo "Embedded extensions: ${FOUND_EXTS:-(none)}"
found_count=0; for _f in $FOUND_EXTS; do found_count=$((found_count + 1)); done

# 3) No forbidden/obsolete extension may be embedded.
for bad in $FORBIDDEN_EXTS; do
  for f in $FOUND_EXTS; do
    [ "$f" = "$bad" ] && fail "obsolete extension is embedded: $bad"
  done
done
ok "no obsolete extension embedded"

# 4) Every expected extension is present, with manifest + id + executable.
expected_count=0
for exp in $EXPECTED_EXTS; do
  expected_count=$((expected_count + 1))
  present=0
  for f in $FOUND_EXTS; do [ "$f" = "$exp" ] && present=1; done
  [ "$present" = 1 ] || fail "expected extension not embedded: $exp"
  extdir="$PLUGINS/$exp"
  [ -f "$extdir/PrivacyInfo.xcprivacy" ] || fail "$exp missing PrivacyInfo.xcprivacy in built bundle"
  eid="$(bundle_id "$extdir")"; want_id="$(expected_id_for "$exp")"
  [ "$eid" = "$want_id" ] || fail "$exp bundle id '$eid' != '$want_id'"
  eexe="$(bundle_exe "$extdir")"
  file "$extdir/$eexe" | grep -q "Mach-O" || fail "$exp executable missing/not Mach-O: $eexe"
  ok "$exp: manifest + id ($eid) + Mach-O executable"
done

# 5) Exact count — no unexpected extra extensions.
[ "$found_count" = "$expected_count" ] \
  || fail "embedded extension count $found_count != expected $expected_count ($EXPECTED_EXTS)"
ok "exactly $expected_count expected extension(s) embedded"

echo "PASS: iOS packaging inventory + privacy manifests verified."
