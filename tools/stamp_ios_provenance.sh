#!/usr/bin/env bash
# Write build-time provenance beside an iOS build artifact. For a release IPA,
# call this after the final export/code-sign and before verification/publishing.
# The sidecar binds the immutable IPA bytes to the current commit and iOS build
# inputs without writing anything into (or otherwise changing) the signed IPA.
#
# Runner.app directories remain supported for the local packaging evidence gate.
# Usage: stamp_ios_provenance.sh [path/to/final.ipa-or-Runner.app]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT="${1:-$ROOT/app/build/ios/iphonesimulator/Runner.app}"

if [ -f "$ARTIFACT" ]; then
  ARTIFACT_TYPE="ipa"
  case "$ARTIFACT" in
    *.ipa) ;;
    *) echo "ERROR: release provenance file must be an .ipa: $ARTIFACT" >&2; exit 1 ;;
  esac
  ARTIFACT_SHA="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
elif [ -d "$ARTIFACT" ]; then
  ARTIFACT_TYPE="app"
  ARTIFACT_SHA="not-applicable-directory"
else
  echo "ERROR: no iOS artifact at $ARTIFACT (build it first)" >&2
  exit 1
fi

ARTIFACT_DIR="$(cd "$(dirname "$ARTIFACT")" && pwd -P)"
ARTIFACT_PATH="$ARTIFACT_DIR/$(basename "$ARTIFACT")"
IOS_INPUT_SHA="$(bash "$ROOT/tools/ios_input_sha.sh")"
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
[ -n "$COMMIT" ] || { echo "ERROR: cannot bind provenance without a git commit" >&2; exit 1; }
WORKTREE="clean"
[ -n "$(git -C "$ROOT" status --porcelain -- app/ios 2>/dev/null)" ] && WORKTREE="dirty"

SIDE="$ARTIFACT.provenance"
SIDE_TMP="$SIDE.tmp.$$"
trap 'rm -f "$SIDE_TMP"' EXIT
{
  echo "provenance_version=1"
  echo "artifact_type=$ARTIFACT_TYPE"
  echo "artifact_path=$ARTIFACT_PATH"
  echo "artifact_sha256=$ARTIFACT_SHA"
  echo "ios_input_sha=$IOS_INPUT_SHA"
  echo "git_commit=$COMMIT"
  echo "ios_worktree=$WORKTREE"
} > "$SIDE_TMP"
mv "$SIDE_TMP" "$SIDE"
trap - EXIT

echo "stamped external provenance $SIDE"
echo "  artifact_type=$ARTIFACT_TYPE"
echo "  artifact_sha256=$ARTIFACT_SHA"
echo "  ios_input_sha=$IOS_INPUT_SHA"
echo "  git_commit=$COMMIT (ios worktree: $WORKTREE)"
