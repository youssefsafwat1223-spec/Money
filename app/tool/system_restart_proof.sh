#!/usr/bin/env bash
# System-wide persistence proof. Installs one bundle once, then launches that
# exact install through arm/write/verify/lifecycle/logout-login phases.
set -euo pipefail

DEVICE="${1:?usage: system_restart_proof.sh <simulator-udid>}"
BUNDLE=""
TARGET="integration_test/system_restart_persistence_test.dart"
OUT="${OUT_DIR:-/tmp/qirsh-system-restart-proof}"
DEFINES="${QIRSH_QA_DEFINES:-$HOME/.qirsh-qa/qa_run_defines.json}"
COMMIT="$(git rev-parse HEAD)"
SOURCE_STATE="clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  SOURCE_STATE="dirty"
fi
mkdir -p "$OUT"

say() { printf '\n=== %s ===\n' "$*"; }

container_path() {
  xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data
}

db_stat() {
  local root db
  root="$(container_path)"
  db="$root/Library/Application Support/money_companion.sqlite"
  if [ ! -f "$db" ]; then
    echo "db=<absent>"
    return
  fi
  printf 'db_path=%s inode=%s size=%s sha256=%s\n' \
    "$db" "$(stat -f%i "$db")" "$(stat -f%z "$db")" \
    "$(shasum -a 256 "$db" | cut -d' ' -f1)"
}

launch_phase() {
  local phase="$1" label="$2" docs logpid waited
  say "LAUNCH $label ($phase)"
  docs="$(container_path)/Documents"
  mkdir -p "$docs"
  printf '%s' "$phase" > "$docs/qa_system_restart_phase.txt"

  xcrun simctl spawn "$DEVICE" log stream --style compact \
    --predicate 'processImagePath CONTAINS "Runner"' \
    > "$OUT/$label.log" 2>&1 &
  logpid=$!
  sleep 2
  xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null
  waited=0
  while [ "$waited" -lt 240 ]; do
    if grep -q 'SYSTEM-RESTART. DONE\|All tests passed\|Some tests failed' \
        "$OUT/$label.log" 2>/dev/null; then
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done
  sleep 2
  kill "$logpid" 2>/dev/null || true
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true

  grep -E '\[SYSTEM-RESTART\]' "$OUT/$label.log" > "$OUT/$label.evidence" || true
  tail -40 "$OUT/$label.evidence" || true
  grep -q 'SYSTEM-RESTART. DONE' "$OUT/$label.log"
  db_stat | tee "$OUT/$label.db.txt"
}

say "BUILD EXACT CURRENT COMMIT"
echo "git_commit=$COMMIT"
echo "source_state=$SOURCE_STATE"
flutter build ios --simulator --debug -t "$TARGET" \
  --dart-define-from-file="$DEFINES" \
  --dart-define="QA_GIT_COMMIT=$COMMIT"

APP="build/ios/iphonesimulator/Runner.app"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"
echo "bundle_id=$BUNDLE version=$VERSION build=$BUILD commit=$COMMIT source_state=$SOURCE_STATE" | tee "$OUT/build.txt"

say "INSTALL ONCE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl uninstall "$DEVICE" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
INSTALL_CONTAINER="$(container_path)"
echo "container=$INSTALL_CONTAINER" | tee "$OUT/container-before.txt"

launch_phase arm arm
launch_phase write session-1-write
for n in 1 2 3 4 5; do
  launch_phase "verify-$n" "restart-$n"
done
launch_phase lifecycle background-foreground
launch_phase logout-login logout-login

say "CONTAINER IDENTITY"
FINAL_CONTAINER="$(container_path)"
echo "before=$INSTALL_CONTAINER"
echo "after=$FINAL_CONTAINER"
test "$INSTALL_CONTAINER" = "$FINAL_CONTAINER"

echo "PASS: language/account/transaction/goal/budget survived five full kills,"
echo "same container; lifecycle was inert; logout wiped intentionally and same-user login reclaimed cleanly."
echo "evidence=$OUT"
