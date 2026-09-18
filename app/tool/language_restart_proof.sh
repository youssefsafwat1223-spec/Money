#!/usr/bin/env bash
# LANGUAGE PERSISTENCE ACROSS A PROCESS RESTART — iOS Simulator.
#
# Answers one question: does a language set through the app's own write path
# survive the app process being killed and started again, on the SAME install?
#
# It exists because a previous measurement said no, and was wrong. That one was
# taken across two `flutter test` invocations — and `flutter test` UNINSTALLS
# the app when it finishes, which destroys the iOS data container. The "next
# process" therefore opened a brand-new database whose settings row had just
# been created with its hardcoded default. Evidence gathered that way measures
# the installer, not the app. `tool/process_restart_proof.sh` said so in its
# header before that mistake was made.
#
# So: install exactly ONCE, then only launch. The phase is written into a file
# in the app's own Documents directory, because a `--dart-define` is fixed at
# compile time and both phases must run the same binary.
#
# The container path is recorded before and after. A changed container means the
# app was reinstalled and the proof is void — which is exactly the confound that
# produced the false finding.
#
# READING THE OUTPUT: each phase ends with "Some tests failed" over a leftover
# SemanticsHandle — the app enables semantics and is still alive when the test
# body returns. The assertions all run BEFORE the `[LANG-PROOF] DONE` marker, so
# DONE is the success signal; its absence is the failure signal. Same as
# process_restart_proof.sh.
set -euo pipefail

DEVICE="${1:?usage: language_restart_proof.sh <simulator-udid>}"
BUNDLE="com.youssefsafwat.mali"
TARGET="integration_test/language_restart_persistence_test.dart"
OUT="${OUT_DIR:-$HOME/.qirsh-qa/language-restart-proof}"
mkdir -p "$OUT"

say() { printf '\n=== %s ===\n' "$*"; }

launch_phase() {
  local phase="$1" label="$2"
  say "LAUNCH ($label) phase=$phase"
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
  local waited=0
  while [ "$waited" -lt 240 ]; do
    if grep -q 'LANG-PROOF. DONE\|All tests passed\|Some tests failed' \
        "$OUT/$label.log" 2>/dev/null; then
      break
    fi
    sleep 5; waited=$((waited + 5))
  done
  sleep 3
  kill "$logpid" 2>/dev/null || true
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  grep -Eo '\[LANG-PROOF\][^$]*|All tests passed|Some tests failed' \
    "$OUT/$label.log" | head -20 || true
}

say "BUILD (once)"
flutter build ios --simulator --debug -t "$TARGET" 2>&1 | tail -2

say "INSTALL (once — nothing after this line reinstalls)"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE" build/ios/iphonesimulator/Runner.app
INSTALL_STAMP="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)"
echo "container: $INSTALL_STAMP"

# Both directions. English first, because it is the one that proves the value
# persisted at all — Arabic is what a fresh settings row already holds. Arabic
# second, because it proves the cached prompt language follows a change BACK
# instead of sticking at whatever it saw first.
for LANG in en ar; do
  say "LANGUAGE: $LANG"
  launch_phase "write:$LANG" "write-$LANG"

  say "TERMINATE (process killed; install untouched)"
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  sleep 3

  launch_phase "verify:$LANG" "restart-$LANG"
done

say "CONTAINER IDENTITY"
NOW="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)"
echo "before: $INSTALL_STAMP"
echo "after : $NOW"
if [ "$INSTALL_STAMP" = "$NOW" ]; then
  echo "SAME container — this was a process restart, NOT a reinstall."
else
  echo "DIFFERENT container — the app WAS reinstalled; the proof is void."
  exit 1
fi
