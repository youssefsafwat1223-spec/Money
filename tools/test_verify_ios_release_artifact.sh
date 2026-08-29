#!/usr/bin/env bash
# Synthetic behavioral regression test for the iOS release artifact contract.
# No signing, Codemagic, TestFlight, Flutter build, or network access is used.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$ROOT/tools/verify_ios_release_artifact.sh"
STAMP="$ROOT/tools/stamp_ios_provenance.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify_ios_release_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

expect_failure() {
  local label="$1"
  local expected="$2"
  shift 2
  local output
  if output="$("$@" 2>&1)"; then
    fail "$label unexpectedly succeeded"
  fi
  printf '%s\n' "$output" | grep -F "$expected" >/dev/null \
    || fail "$label failed for the wrong reason; expected '$expected', got: $output"
  pass "$label"
}

write_plist() {
  local path="$1"
  local bundle_id="$2"
  local executable="$3"
  cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleExecutable</key><string>$executable</string>
</dict>
</plist>
EOF
}

make_ipa() {
  local output="$1"
  local name="$2"
  local stage="$TMP/stage-$name"
  local app="$stage/Payload/Runner.app"
  local extension="$app/PlugIns/ShareBankMessage.appex"

  mkdir -p "$extension"
  write_plist "$app/Info.plist" "com.youssefsafwat.mali" "Runner"
  write_plist "$extension/Info.plist" \
    "com.youssefsafwat.mali.ShareBankMessage" "ShareBankMessage"
  printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' \
    > "$app/PrivacyInfo.xcprivacy"
  cp "$app/PrivacyInfo.xcprivacy" "$extension/PrivacyInfo.xcprivacy"
  cp /usr/bin/true "$app/Runner"
  cp /usr/bin/true "$extension/ShareBankMessage"
  chmod +x "$app/Runner" "$extension/ShareBankMessage"
  mkdir -p "$(dirname "$output")"
  (cd "$stage" && zip -q -r "$output" Payload)
}

legacy_stamp_at_verify_accepts() {
  local ipa="$1"
  local extract="$TMP/legacy-extract"
  unzip -q "$ipa" 'Payload/*' -d "$extract"
  # This is the defective lifecycle's positive control: provenance is created
  # for a throwaway extraction during verification, so no pre-existing IPA
  # sidecar is required. The synthetic payload must pass this control or the
  # missing-provenance regression assertion below would be vacuous.
  bash "$STAMP" "$extract/Payload/Runner.app" >/dev/null
  bash "$ROOT/app/tools/verify_ios_packaging.sh" \
    "$extract/Payload/Runner.app" >/dev/null
}

echo "Synthetic iOS release artifact verification"

ZERO="$TMP/zero"
mkdir -p "$ZERO"
expect_failure "zero candidate IPAs fail closed" "found 0" \
  bash "$VERIFY" "$ZERO"

MULTIPLE="$TMP/multiple"
mkdir -p "$MULTIPLE"
: > "$MULTIPLE/first.ipa"
: > "$MULTIPLE/second.ipa"
expect_failure "multiple candidate IPAs fail closed" "found 2" \
  bash "$VERIFY" "$MULTIPLE"

SINGLE="$TMP/single"
IPA="$SINGLE/synthetic.ipa"
make_ipa "$IPA" "single"
SHA_BEFORE="$(shasum -a 256 "$IPA" | awk '{print $1}')"

legacy_stamp_at_verify_accepts "$IPA" \
  || fail "non-vacuity control: legacy stamp-at-verify rejected valid fixture"
pass "non-vacuity control: legacy stamp-at-verify accepts unstamped fixture"

# Non-vacuity: the old verifier manufactured provenance on an extracted copy and
# would pass this valid-but-unstamped IPA. The fixed verifier must reject it and
# must not create provenance as a side effect of verification.
expect_failure "missing pre-existing provenance is rejected" \
  "missing pre-existing build-time provenance sidecar" \
  bash "$VERIFY" "$IPA"
[ ! -e "$IPA.provenance" ] \
  || fail "verification synthesized provenance instead of requiring build-time evidence"
pass "verification does not synthesize provenance"

bash "$STAMP" "$IPA" >/dev/null
grep -Fx "artifact_sha256=$SHA_BEFORE" "$IPA.provenance" >/dev/null \
  || fail "build-time provenance did not record the exact IPA sha256"
CURRENT_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
grep -Fx "git_commit=$CURRENT_COMMIT" "$IPA.provenance" >/dev/null \
  || fail "build-time provenance did not record the current commit"
pass "build-time sidecar records the exact IPA sha256 and commit"

VERIFY_OUTPUT="$(bash "$VERIFY" "$SINGLE")"
printf '%s\n' "$VERIFY_OUTPUT" | grep -F "sha256=$SHA_BEFORE" >/dev/null \
  || fail "successful verification did not attest the selected IPA sha256"
pass "exactly one candidate with matching pre-existing provenance verifies"

cp "$IPA.provenance" "$IPA.provenance.valid"
sed 's/^artifact_sha256=.*/artifact_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$IPA.provenance.valid" > "$IPA.provenance"
expect_failure "stale provenance cannot authorize different IPA bytes" \
  "artifact sha256 does not match exact IPA" bash "$VERIFY" "$IPA"
cp "$IPA.provenance.valid" "$IPA.provenance"

sed 's/^git_commit=.*/git_commit=0000000000000000000000000000000000000000/' \
  "$IPA.provenance.valid" > "$IPA.provenance"
expect_failure "stale provenance commit is rejected" \
  "provenance commit is stale" bash "$VERIFY" "$IPA"
cp "$IPA.provenance.valid" "$IPA.provenance"

SHA_AFTER="$(shasum -a 256 "$IPA" | awk '{print $1}')"
[ "$SHA_AFTER" = "$SHA_BEFORE" ] \
  || fail "stamping/verification changed IPA bytes ($SHA_BEFORE -> $SHA_AFTER)"
pass "stamping and verification do not alter signed IPA bytes"

echo "PASS: synthetic iOS release artifact contract"
