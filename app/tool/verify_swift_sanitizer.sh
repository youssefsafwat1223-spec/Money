#!/usr/bin/env bash
# Verifies the Share Extension's Swift PII sanitizer.
#
# The Swift copy has no XCTest target, so there is nowhere to assert its
# behaviour from — and it is the copy that feeds an off-device AI service, so
# "no test target" is not an acceptable reason to leave it unchecked. This
# script lifts sanitize() out of the shipped source VERBATIM and runs it, so
# the code under test is the code that ships rather than a transcription.
#
# Keep in lockstep with:
#   app/lib/engine/privacy/sms_sanitizer.dart
#   supabase/functions/_shared/sms_redaction.ts
set -euo pipefail
cd "$(dirname "$0")/.."
src="ios/BankMessageShortcuts/BankMessageShortcuts.swift"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$src" "$work/check.swift" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8').read()
start = s.index('  private static func sanitize(_ text: String) throws -> String {')
end = s.index('\n  }\n', start) + len('\n  }\n')
body = s[start:end].replace('private static func', 'func', 1)
# sanitize() throws when a rule will not compile; the standalone harness has no
# BackendCaptureError, so give it one with the single case sanitize() raises.
body = 'enum BackendCaptureError: Error { case sanitizerUnavailable }\n\n' + body
body = '\n'.join(l[2:] if l.startswith('  ') else l for l in body.split('\n'))
open(out, 'w', encoding='utf-8').write('import Foundation\n\n' + body + '''
let cases: [(String, String, String)] = [
  // An IBAN is alphanumeric, so the digits-only account rule can never reach
  // it. Before the IBAN rule existed here, this reached the model intact.
  ("حوالة من SA0380000000608010167519 بمبلغ 500", "contains", "[IBAN]"),
  ("Your OTP is 483920 do not share", "contains", "[OTP]"),
  ("رمز التحقق: 8391", "contains", "[OTP]"),
  ("بطاقة 4539 1488 0343 6467 خصم", "contains", "[CARD]"),
  ("اتصل 0551234567 للتأكيد", "contains", "[PHONE]"),
  ("اتصل 01012345678 للتأكيد", "contains", "[PHONE]"),
  ("call +966551234567", "contains", "[PHONE]"),
  ("حساب 1234567890123 خصم", "contains", "[ACCOUNT]"),
  // The OTP cue survives, so the message stays classifiable as an OTP.
  ("Your OTP is 483920", "equals", "Your OTP is [OTP]"),
  // Cue-anchoring exists so amounts are never destroyed by shape alone.
  ("شراء بمبلغ 250.75 ريال", "equals", "شراء بمبلغ 250.75 ريال"),
  // Card must win over the generic account rule on a bare 16-digit run,
  // which is only true while the specific rules run first.
  ("4539148803436467", "equals", "[CARD]"),
  // Arabic-Indic digits: every pattern used ASCII \\d, so identifiers written
  // in the digits half this market uses were forwarded to the model intact.
  ("حساب ١٢٣٤٥٦٧٨٩٠١٢٣ خصم", "contains", "[ACCOUNT]"),
  ("بطاقة ٤٥٣٩١٤٨٨٠٣٤٣٦٤٦٧", "contains", "[CARD]"),
  ("اتصل ٠٥٥١٢٣٤٥٦٧", "contains", "[PHONE]"),
  ("حساب ۱۲۳۴۵۶۷۸۹۰۱۲۳", "contains", "[ACCOUNT]"),
  // ...without costing the amounts their reason for existing.
  ("مبلغ ١٢٥٠ ريال", "equals", "مبلغ ١٢٥٠ ريال"),
  // A lower-case IBAN is the same identifier.
  ("IBAN sa0380000000608010167519", "contains", "[IBAN]"),
  // No raw identifier may survive.
  ("SA0380000000608010167519", "notContains", "SA038000000060801"),
]
var failed = 0
for (input, mode, expected) in cases {
  let out = try! sanitize(input)
  let ok: Bool
  switch mode {
  case "equals": ok = out == expected
  case "notContains": ok = !out.contains(expected)
  default: ok = out.contains(expected)
  }
  if !ok { failed += 1 }
  print("\\(ok ? "PASS" : "FAIL") \\(mode) [\\(expected)]  \\(input)  ->  \\(out)")
}
print(failed == 0 ? "OK — swift sanitizer parity holds" : "FAILED — \\(failed) case(s)")
exit(failed == 0 ? 0 : 1)
''')
PY

swift "$work/check.swift"
