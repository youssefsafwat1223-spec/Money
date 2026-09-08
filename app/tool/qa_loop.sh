#!/bin/zsh
# Physical-device QA loop. Profile configuration, QIRSH_INTEGRATION_TEST define
# passed ONLY here (never in project settings), default DerivedData reused.
#   qa_loop.sh config   # only when the Dart target or dart-defines change (runs pod install)
#   qa_loop.sh build    # build-for-testing: incremental; emits the .xctestrun
#   qa_loop.sh run      # test-without-building: no compile, no link
set -u
# Local, gitignored scratch dir holding qa_run_defines.json (QA credentials)
# and the run logs. Override with QA_DIR; nothing here is committed.
S=${QA_DIR:-$HOME/.qirsh-qa}
APP=${QIRSH_APP:-$(cd "$(dirname "$0")/.." && pwd)}
# Reuse the DEFAULT DerivedData. Passing -derivedDataPath would force a cold
# build; so would varying the build settings below, which apply to every target
# and rehash each Pod (measured: 1000s full vs 206-901s incremental).
# Pick the DerivedData that actually HOLDS build products, not merely the most
# recently touched one: xcodebuild can create a second Runner-* dir (a different
# workspace-path hash), and `ls -dt` then selects a directory with no .xctestrun.
DD=$(dirname "$(dirname "$(dirname "$(ls -t $HOME/Library/Developer/Xcode/DerivedData/Runner-*/Build/Products/*.xctestrun 2>/dev/null | head -1)")")" 2>/dev/null)
[[ -z "$DD" ]] && DD=$(ls -dt $HOME/Library/Developer/Xcode/DerivedData/Runner-* | head -1)
UDID=${QIRSH_DEVICE:?set QIRSH_DEVICE to the iPhone udid}
DEFS='GCC_PREPROCESSOR_DEFINITIONS=$(inherited) QIRSH_INTEGRATION_TEST=1'
# RunnerTests.swift does `@testable import Runner`, which needs ENABLE_TESTABILITY —
# Debug-only by default. Excluding it (command line only, project untouched) keeps
# Profile buildable without recompiling Runner and every Swift Pod with testability.
EXCL='EXCLUDED_SOURCE_FILE_NAMES=RunnerTests.swift'
case "${1:-}" in
  config)
    cd $APP && flutter build ios --config-only --profile -t integration_test/post_auth_journeys_test.dart --dart-define-from-file="$S/qa_run_defines.json" 2>&1 | tail -1
    grep -E "^FLUTTER_TARGET=" $APP/ios/Flutter/Generated.xcconfig ;;
  build)
    cd $APP/ios && t0=$(date +%s)
    xcodebuild build-for-testing -workspace Runner.xcworkspace -scheme Runner -configuration Profile \
      -destination "id=$UDID" "$DEFS" "$EXCL" > "$S/bft.log" 2>&1; rc=$?
    echo "build-for-testing exit=$rc in $(( $(date +%s) - t0 ))s"
    grep -E "error:|warning: .*QIRSH" "$S/bft.log" | head -3
    ls -la $DD/Build/Products/*.xctestrun 2>/dev/null | awk '{print $5, $9}' ;;
  run)
    XR=$(ls -t $HOME/Library/Developer/Xcode/DerivedData/Runner-*/Build/Products/*.xctestrun 2>/dev/null | head -1)
    [ -n "$XR" ] || { echo "no .xctestrun — run build first"; exit 2; }
    echo "xctestrun: $XR" 
    # Run from a neutral cwd: inside app/ios xcodebuild also loads the workspace
    # scheme, reports its supported platforms as empty, and rejects the device.
    cd "$S" && t0=$(date +%s); rm -rf "$S/qa_run.xcresult"
    xcodebuild test-without-building -xctestrun "$XR" -destination "platform=iOS,id=$UDID" \
      -only-testing:RunnerTests/RunnerIntegrationTests -default-test-execution-time-allowance 900 \
      -resultBundlePath "$S/qa_run.xcresult" > "$S/twb.log" 2>&1; rc=$?
    echo "test-without-building exit=$rc in $(( $(date +%s) - t0 ))s"
    grep -E "\[QA\]" "$S/twb.log" | cut -c1-170
    grep -E "\*\* TEST (SUCCEEDED|FAILED) \*\*|Testing failed:|ptrace|encountered an error|Test Case .* (passed|failed)" "$S/twb.log" | tail -4 | cut -c1-150 ;;
  *) echo "usage: qa_loop.sh config|build|run"; exit 1 ;;
esac
