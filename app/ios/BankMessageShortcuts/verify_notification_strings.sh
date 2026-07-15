#!/usr/bin/env bash
# Static regression guard for the generic-fallback notification wording in
# BankMessageShortcuts.swift.
#
# Why a shell script and not an XCTest: BankMessageShortcuts.swift lives only
# in the BankMessageShortcuts App Intent extension target. RunnerTests is
# bound to the separate Runner app target and cannot import extension-only
# symbols without adding a new Xcode test target (real project surgery, out
# of scope for this fix). This script is the lightweight, CI-runnable
# equivalent: it fails loudly if the old, vague wording reappears, or if the
# corrected wording is missing.
#
# Run from anywhere; exits non-zero on failure.

set -euo pipefail

FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/BankMessageShortcuts.swift"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# The old string implied a reviewable transaction already existed in the app
# ("a message was received, go check") — it must never reappear.
if grep -q "تم استلام رسالة من" "$FILE"; then
  fail "old vague fallback wording ('تم استلام رسالة من ...') is still present in $FILE"
fi
if grep -q "تم استلام رسالة بنكية" "$FILE"; then
  fail "old vague fallback wording ('تم استلام رسالة بنكية') is still present in $FILE"
fi

# The corrected, honest wording must be present exactly once each.
grep -q "لم نتمكن من تحليل رسالة" "$FILE" \
  || fail "corrected sender-specific fallback wording not found in $FILE"
grep -q "لم نتمكن من تحليل الرسالة البنكية" "$FILE" \
  || fail "corrected no-sender fallback wording not found in $FILE"

echo "OK: generic fallback notification wording is the corrected, honest version."
