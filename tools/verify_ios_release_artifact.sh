#!/usr/bin/env bash
# Verify a final iOS IPA without manufacturing provenance or changing its bytes.
#
# The input may be one explicit IPA path (when the build system already selected
# it) or a directory containing candidates. Directory mode fails closed unless
# there is exactly one top-level *.ipa. --resolve-only performs that same strict
# selection for a caller that must retain the resolved path for stamping,
# verification, and publication.
#
# A release sidecar must already exist beside the IPA. It is produced after the
# final export/code-sign by tools/stamp_ios_provenance.sh and binds the exact IPA
# SHA-256 to its canonical path, git commit, iOS input digest, and worktree state.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "ERROR: $*" >&2; exit 1; }

canonical_path() {
  local target="$1"
  local target_dir
  target_dir="$(cd "$(dirname "$target")" && pwd -P)"
  printf '%s/%s\n' "$target_dir" "$(basename "$target")"
}

resolve_ipa() {
  local target="$1"
  local candidate=""
  local count=0
  local found

  if [ -d "$target" ]; then
    while IFS= read -r -d '' found; do
      candidate="$found"
      count=$((count + 1))
    done < <(find "$target" -maxdepth 1 -type f -name '*.ipa' -print0)
    [ "$count" -eq 1 ] \
      || fail "expected exactly one IPA in '$target'; found $count"
    canonical_path "$candidate"
    return
  fi

  [ -f "$target" ] || fail "no IPA at '$target'"
  case "$target" in
    *.ipa) ;;
    *) fail "artifact is not an IPA: '$target'" ;;
  esac
  canonical_path "$target"
}

provenance_value() {
  local key="$1"
  local side="$2"
  awk -v wanted="$key" '
    index($0, wanted "=") == 1 {
      count += 1
      value = substr($0, length(wanted) + 2)
    }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$side"
}

MODE="verify"
if [ "${1:-}" = "--resolve-only" ]; then
  MODE="resolve"
  shift
fi
[ "$#" -eq 1 ] \
  || fail "usage: verify_ios_release_artifact.sh [--resolve-only] <final.ipa-or-candidate-directory>"

IPA="$(resolve_ipa "$1")"
if [ "$MODE" = "resolve" ]; then
  printf '%s\n' "$IPA"
  exit 0
fi

SIDE="$IPA.provenance"
[ -f "$SIDE" ] \
  || fail "missing pre-existing build-time provenance sidecar: $SIDE"

SHA_BEFORE="$(shasum -a 256 "$IPA" | awk '{print $1}')"
CURRENT_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
[ -n "$CURRENT_COMMIT" ] \
  || fail "cannot verify provenance without a current git commit"
CURRENT_INPUT_SHA="$(bash "$ROOT/tools/ios_input_sha.sh")"
CURRENT_WORKTREE="clean"
[ -n "$(git -C "$ROOT" status --porcelain -- app/ios 2>/dev/null)" ] \
  && CURRENT_WORKTREE="dirty"

REC_VERSION="$(provenance_value provenance_version "$SIDE")" \
  || fail "provenance_version must occur exactly once in $SIDE"
REC_TYPE="$(provenance_value artifact_type "$SIDE")" \
  || fail "artifact_type must occur exactly once in $SIDE"
REC_PATH="$(provenance_value artifact_path "$SIDE")" \
  || fail "artifact_path must occur exactly once in $SIDE"
REC_ARTIFACT_SHA="$(provenance_value artifact_sha256 "$SIDE")" \
  || fail "artifact_sha256 must occur exactly once in $SIDE"
REC_INPUT_SHA="$(provenance_value ios_input_sha "$SIDE")" \
  || fail "ios_input_sha must occur exactly once in $SIDE"
REC_COMMIT="$(provenance_value git_commit "$SIDE")" \
  || fail "git_commit must occur exactly once in $SIDE"
REC_WORKTREE="$(provenance_value ios_worktree "$SIDE")" \
  || fail "ios_worktree must occur exactly once in $SIDE"

[ "$REC_VERSION" = "1" ] || fail "unsupported provenance_version=$REC_VERSION"
[ "$REC_TYPE" = "ipa" ] || fail "provenance artifact_type=$REC_TYPE, expected ipa"
[ "$REC_PATH" = "$IPA" ] \
  || fail "provenance path '$REC_PATH' does not match exact IPA '$IPA'"
[ "$REC_ARTIFACT_SHA" = "$SHA_BEFORE" ] \
  || fail "provenance artifact sha256 does not match exact IPA (recorded=$REC_ARTIFACT_SHA actual=$SHA_BEFORE)"
[ "$REC_INPUT_SHA" = "$CURRENT_INPUT_SHA" ] \
  || fail "provenance iOS input sha is stale (recorded=$REC_INPUT_SHA current=$CURRENT_INPUT_SHA)"
[ "$REC_COMMIT" = "$CURRENT_COMMIT" ] \
  || fail "provenance commit is stale (recorded=$REC_COMMIT current=$CURRENT_COMMIT)"
[ "$REC_WORKTREE" = "$CURRENT_WORKTREE" ] \
  || fail "provenance worktree state changed (recorded=$REC_WORKTREE current=$CURRENT_WORKTREE)"

echo "FINAL artifact provenance matches the exact bytes to be distributed:"
echo "  path       = $IPA"
echo "  sha256     = $SHA_BEFORE"
echo "  git_commit = $CURRENT_COMMIT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ios_artifact.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Read-only inspection of the exact IPA. Exactly one top-level app is required;
# a malformed payload cannot gain authority via arbitrary first-match selection.
unzip -q "$IPA" 'Payload/*' -d "$TMP"
APP=""
APP_COUNT=0
while IFS= read -r -d '' FOUND_APP; do
  APP="$FOUND_APP"
  APP_COUNT=$((APP_COUNT + 1))
done < <(find "$TMP/Payload" -maxdepth 1 -type d -name '*.app' -print0)
[ "$APP_COUNT" -eq 1 ] \
  || fail "expected exactly one Payload/*.app inside '$IPA'; found $APP_COUNT"

bash "$ROOT/app/tools/verify_ios_packaging.sh" "$APP" "$SIDE"

SHA_AFTER="$(shasum -a 256 "$IPA" | awk '{print $1}')"
[ "$SHA_AFTER" = "$SHA_BEFORE" ] \
  || fail "IPA bytes changed during verification (before=$SHA_BEFORE after=$SHA_AFTER)"

echo "VERIFIED immutable release artifact: $IPA (sha256=$SHA_AFTER)"
