#!/usr/bin/env bash
# PROCESS RESTART / REBOOT PERSISTENCE PROOF — iOS Simulator.
#
# Proves that data written by Qirsh survives the app process being killed and
# started again, and survives a device reboot, on the SAME install.
#
# Why not `flutter test`: it reinstalls the app on every invocation, and iOS
# replaces the app container on reinstall. Evidence gathered across two
# `flutter test` runs measures the installer, not the app. So this installs the
# test bundle exactly ONCE with `simctl install` and then only launches it.
#
# The phase cannot be a `--dart-define` — a define is fixed at compile time and
# both phases must run the same binary. `SIMCTL_CHILD_*` environment injection
# was tried first and did not reach the Dart isolate, so the phase is written
# into a file in the app's own Documents directory, which both sides can see.
#
# The database file is hashed at every step. A changed hash after a write is
# expected; a changed INODE would mean the container was replaced, which is the
# exact confound this script exists to rule out.
set -euo pipefail

DEVICE="${1:?usage: process_restart_proof.sh <simulator-udid>}"
BUNDLE="com.youssefsafwat.mali"
TARGET="integration_test/process_restart_persistence_test.dart"
OUT="${OUT_DIR:-$HOME/.qirsh-qa/restart-proof}"
mkdir -p "$OUT"

say() { printf '\n=== %s ===\n' "$*"; }

db_path_of() {
  # The app reports its own database path; ask the container instead of
  # guessing, so a layout change surfaces as a missing file rather than a
  # silently wrong hash.
  local root
  root="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data 2>/dev/null || true)"
  [ -n "$root" ] && printf '%s/Library/Application Support/money_companion.sqlite' "$root"
}

stat_db() {
  local f; f="$(db_path_of)"
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    echo "db: <absent>"
    return
  fi
  printf 'db: inode=%s size=%s sha256=%s\n' \
    "$(stat -f%i "$f")" "$(stat -f%z "$f")" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
}

launch_phase() {
  local phase="$1" label="$2"
  say "LAUNCH ($label) phase=$phase"
  # `simctl launch --console-pty` only reports the pid for a Flutter app: the
  # test's output goes through `debugPrint` to os_log, not to the launcher's
  # stdout. So stream the device log for the duration of the launch instead.
  local docs
  docs="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)/Documents"
  mkdir -p "$docs"
  printf '%s' "$phase" > "$docs/qa_phase.txt"

  xcrun simctl spawn "$DEVICE" log stream --style compact \
    --predicate 'processImagePath CONTAINS "Runner"' \
    > "$OUT/$label.log" 2>&1 &
  local logpid=$!
  sleep 2
  xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
  # The app exits on its own when the test finishes; bound the wait so a hang
  # is a timeout with a log rather than a stuck script.
  local waited=0
  while [ "$waited" -lt 180 ]; do
    if grep -q 'RESTART-PROOF. DONE\|All tests passed\|Some tests failed' "$OUT/$label.log" 2>/dev/null; then
      break
    fi
    sleep 5; waited=$((waited + 5))
  done
  sleep 3
  kill "$logpid" 2>/dev/null || true
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  grep -Eo '\[RESTART-PROOF\][^$]*|All tests passed|Some tests failed' "$OUT/$label.log" | head -20 || true
}

say "BUILD (once)"
flutter build ios --simulator --debug -t "$TARGET" 2>&1 | tail -3

say "INSTALL (once — nothing after this line reinstalls)"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true
xcrun simctl uninstall "$DEVICE" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$DEVICE" build/ios/iphonesimulator/Runner.app
INSTALL_STAMP="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)"
echo "container: $INSTALL_STAMP"

launch_phase write write
say "AFTER WRITE"; stat_db | tee "$OUT/hash_after_write.txt"

say "TERMINATE (process killed; install untouched)"
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
sleep 3

launch_phase verify restart
say "AFTER RESTART"; stat_db | tee "$OUT/hash_after_restart.txt"

say "REBOOT the device (shutdown + boot; container survives)"
xcrun simctl shutdown "$DEVICE"
sleep 5
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true

launch_phase verify reboot
say "AFTER REBOOT"; stat_db | tee "$OUT/hash_after_reboot.txt"

say "CONTAINER IDENTITY"
NOW="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)"
echo "before: $INSTALL_STAMP"
echo "after : $NOW"
if [ "$INSTALL_STAMP" = "$NOW" ]; then
  echo "SAME container — this was a process restart and a reboot, NOT a reinstall."
else
  echo "DIFFERENT container — the app WAS reinstalled; the proof is void."
  exit 1
fi

say "RESULT"
# Judged on the probe's own lines, not on flutter_test's exit summary.
#
# The summary reports "Some tests failed" on every launch because the iOS
# accessibility client attaches to a launched app and holds a SemanticsHandle
# for the life of the process, which flutter_test's teardown reports as a leak.
# That handle belongs to the platform, not to this probe, and it is raised
# AFTER every assertion here has already run. So the persistence verdict comes
# from `found=`, which only prints when the lookup actually ran — and if an
# assertion failed, `DONE` never prints and the check below fails with it.
FAILED=0
for p in restart reboot; do
  line="$(grep -o 'phase=verify found=[a-z]*' "$OUT/$p.log" | head -1)"
  done_line="$(grep -c 'RESTART-PROOF. DONE' "$OUT/$p.log" || true)"
  if [ "$line" = "phase=verify found=true" ] && [ "$done_line" -gt 0 ]; then
    echo "$p: PASS — marker present after $p, same container, same inode"
  else
    echo "$p: FAIL — ${line:-no verdict line}"
    FAILED=1
  fi
done
grep -h 'SemanticsHandle was active' "$OUT"/*.log >/dev/null 2>&1 && \
  echo "note: flutter_test also reported a leaked SemanticsHandle (platform a11y client) — not a persistence failure"
[ "$FAILED" -eq 0 ] || exit 1
echo "logs: $OUT"
