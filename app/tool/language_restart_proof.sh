#!/usr/bin/env bash
# LANGUAGE PERSISTENCE ACROSS A PROCESS RESTART — iOS Simulator.
#
# Answers one question: does a language chosen in Settings survive the app
# process being killed and started again, on the SAME install — and does the
# cold-start unlock prompt come out in it?
#
# Three launches per language, all on one install:
#   settings — tap the shell's settings icon, tap Language, tap the language.
#              Leaves the app lock ARMED.
#   native   — cold start, no interception at all: iOS draws its own passcode
#              sheet with the app's prompt inside it, and the host photographs
#              it. The run then hangs — a native sheet stops frame production —
#              which is why this phase is photographed and killed rather than
#              waited on. It is the only capture of the string as the user sees
#              it, rather than as the channel carries it.
#   verify   — cold start with the lock armed; read the prompt string off the
#              platform channel and check it against the persisted setting.
#              Stands the gate down at the end.
#   ui       — same install, gate stood down, so the rendered copy and the
#              layout direction can be read.
#
# The gate is left DISARMED by `verify`. That matters: the flag is sticky, and a
# run killed between `settings` and `verify` leaves it armed with no way in —
# two earlier capture runs were lost to exactly that. If this script is
# interrupted in that window, clear it before the next run.
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

# $3, when given, is a screenshot path. It is taken BEFORE the terminate below:
# `launch_phase` kills the app when the phase is done, and a screenshot after
# that is a picture of the Springboard. (It was, once.)
launch_phase() {
  local phase="$1" label="$2" shot="${3:-}"
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
  if [ -n "$shot" ]; then
    sleep 2
    xcrun simctl io "$DEVICE" screenshot "$shot" >/dev/null 2>&1 || true
    echo "screenshot: $shot"
  fi
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  grep -Eo '\[LANG-PROOF\][^$]*|All tests passed|Some tests failed' \
    "$OUT/$label.log" | head -20 || true
}

say "BUILD (once)"
# QA credentials only. NOTHING here forces a language: the app must choose it
# through its own Settings screen, or the run measures the harness.
DEFINES="${QIRSH_QA_DEFINES:-$HOME/.qirsh-qa/qa_run_defines.json}"
flutter build ios --simulator --debug -t "$TARGET" \
  --dart-define-from-file="$DEFINES" 2>&1 | tail -2

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
  launch_phase "settings:$LANG" "settings-$LANG"

  say "TERMINATE (process killed; install untouched)"
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  sleep 3

  say "NATIVE PROMPT ($LANG) — no interception; iOS draws it"
  xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
  # The gate prompts within the first frames; 40s is generous. Nothing is
  # awaited, because the sheet has already stopped the run by then.
  sleep 40
  xcrun simctl io "$DEVICE" screenshot "$OUT/applock-native-prompt-$LANG.png" \
    >/dev/null 2>&1 || true
  echo "screenshot: $OUT/applock-native-prompt-$LANG.png"
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  sleep 3

  launch_phase "verify:$LANG" "restart-$LANG"

  say "TERMINATE (again; still the same install)"
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  sleep 3

  # The `ui` phase ends with the Language picker open over the settings list, so
  # this one frame carries both the new control and the language it renders in.
  launch_phase "ui:$LANG" "ui-$LANG" "$OUT/language-$LANG.png"
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
