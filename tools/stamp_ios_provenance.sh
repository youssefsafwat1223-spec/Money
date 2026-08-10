#!/usr/bin/env bash
# MALI-043 closure — stamp a freshly-built Runner.app with the provenance of the
# iOS source tree it was built from. Run this IMMEDIATELY after
# `flutter build ios --simulator` (or any Runner.app build) so
# verify_ios_packaging.sh can prove the artifact is current, not stale.
#
# Writes a sidecar `<Runner.app>.provenance` next to (not inside) the bundle.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/app/build/ios/iphonesimulator/Runner.app}"
[ -d "$APP" ] || { echo "no Runner.app at $APP (build it first)" >&2; exit 1; }

SHA="$(bash "$ROOT/tools/ios_input_sha.sh")"
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
DIRTY="clean"
[ -n "$(git -C "$ROOT" status --porcelain app/ios 2>/dev/null)" ] && DIRTY="dirty"

SIDE="$APP.provenance"
{
  echo "ios_input_sha=$SHA"
  echo "git_commit=$COMMIT"
  echo "ios_worktree=$DIRTY"
} > "$SIDE"
echo "stamped $SIDE"
echo "  ios_input_sha=$SHA"
echo "  git_commit=$COMMIT (ios worktree: $DIRTY)"
