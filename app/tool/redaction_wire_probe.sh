#!/usr/bin/env bash
# LIVE WIRE PROBE — does the DEPLOYED server-side redaction actually strip PII?
#
# Closes the last privacy claim that rested on unit evidence. Everything else
# about the sanitizers is proven by tests over the same source and by the
# deployed bytes being identical to HEAD; this asks the deployed RUNTIME.
#
# Zero AI cost by construction. `captureProcessingConsent` requires
# cloud_processing_enabled=true to proceed, and computes
# aiAllowed = allowAi && ai_consent_granted. With AI consent OFF the rule parser
# runs alone, no Gemini call is made, and an unparseable message is stored
# `rejected` with its RE-SANITIZED text — which is exactly the value under test.
#
# Synthetic data, a throwaway install id, and the row is deleted at the end.
# Uses only the public anon key plus the device secret the server itself mints:
# no service-role key is read or needed.
set -uo pipefail

URL="https://rjwphwsefnuotpbtuycf.supabase.co"
ANON=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.qirsh-qa/qa_run_defines.json')))['SUPABASE_ANON_KEY'])")
INSTALL="qa-redaction-probe-$(date +%s)"
MARKER="QIRSHWIREPROBE$(date +%s)"
PAYLOAD="probe-$(date +%s)"

hdr=(-H "Content-Type: application/json" -H "apikey: $ANON" -H "Authorization: Bearer $ANON")

say() { printf '\n── %s\n' "$1"; }

say "1. register a throwaway device"
SECRET=$(curl -s "${hdr[@]}" -X POST "$URL/functions/v1/register-device" \
  -d "{\"installId\":\"$INSTALL\",\"platform\":\"ios\"}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('deviceSecret',''))")
[ -n "$SECRET" ] || { echo "FAIL: no device secret"; exit 1; }
echo "   got a ${#SECRET}-char secret"

say "2. cloud ON, AI OFF — proceeds, but never calls the model"
curl -s "${hdr[@]}" -X POST "$URL/functions/v1/set-device-consent" \
  -d "{\"installId\":\"$INSTALL\",\"deviceSecret\":\"$SECRET\",\"ai_consent_granted\":false,\"cloud_processing_enabled\":true,\"schema_version\":1}" | head -c 200
echo

# Every PII class the sanitizers claim to handle, plus a greppable marker.
# Deliberately NOT parseable as a transaction, so it lands `rejected` and its
# sanitized text is persisted.
SMS="$MARKER تنبيه امني
حوالة الى: سارة الاسمري
ايبان: SA0380000000608010167519
ايبان صغير: sa4420000001234567891234
بطاقة: 4539 1488 0343 6467
جوال: 0551234567
حساب: 1234567890123
حساب بالهندي: ١٢٣٤٥٦٧٨٩٠١٢٣
رمز التحقق: 483920
Your OTP is 918273"

say "3. send it through the DEPLOYED process-ios-sms"
BODY=$(python3 - "$INSTALL" "$SECRET" "$PAYLOAD" "$SMS" <<'PY'
import json, sys
install, secret, payload, sms = sys.argv[1:5]
print(json.dumps({
    "schema_version": 1, "payloadId": payload, "installId": install,
    "deviceSecret": secret, "smsText": sms, "sanitizedText": sms,
    "sender": "QA-PROBE", "senderId": "QA-PROBE", "senderName": "QA-PROBE",
    "receivedAt": "2026-09-16T00:00:00.000Z", "tzOffsetMinutes": 180,
    "locale": "ar_SA", "source": "ios_shortcut", "allowAi": False,
}))
PY
)
curl -s "${hdr[@]}" -X POST "$URL/functions/v1/process-ios-sms" -d "$BODY" | head -c 400
echo

say "4. read back what the SERVER stored"
STORED=$(curl -s "${hdr[@]}" -X POST "$URL/functions/v1/sync-captures" \
  -d "{\"installId\":\"$INSTALL\",\"deviceSecret\":\"$SECRET\"}")
python3 - "$STORED" "$MARKER" <<'PY'
import json, sys, re
raw, marker = sys.argv[1], sys.argv[2]
d = json.loads(raw)
caps = d.get('captures', [])
if not caps:
    print("FAIL: nothing came back —", json.dumps(d)[:300]); sys.exit(1)
text = next((c.get('sanitized_text') or c.get('sanitizedText') or '' for c in caps), '')
if not text:
    print("FAIL: no sanitized_text stored —", json.dumps(caps)[:400]); sys.exit(1)
print("   stored text:\n     " + text.replace("\n", "\n     "))

leaks = {
    'IBAN (upper)':        'SA0380000000608010167519',
    'IBAN (lower)':        'sa4420000001234567891234',
    'card':                '4539 1488 0343 6467',
    'card (joined)':       '4539148803436467',
    'Saudi mobile':        '0551234567',
    'account':             '1234567890123',
    'Arabic-Indic account':'١٢٣٤٥٦٧٨٩٠١٢٣',
    'OTP (ar cue)':        '483920',
    'OTP (en cue)':        '918273',
    'beneficiary name':    'سارة',
}
bad = {k: v for k, v in leaks.items() if v in text}
print()
if marker not in text:
    print("FAIL: the marker itself is missing — wrong row?"); sys.exit(1)
print(f"   marker {marker} present, so this is the right row")
for k in leaks:
    print(f"   {'LEAK ***' if k in bad else 'redacted'}  {k}")
sys.exit(1 if bad else 0)
PY
RESULT=$?

say "5. clean up — ack deletes the row"
curl -s "${hdr[@]}" -X POST "$URL/functions/v1/sync-captures" \
  -d "{\"installId\":\"$INSTALL\",\"deviceSecret\":\"$SECRET\",\"ackPayloadIds\":[\"$PAYLOAD\"]}" | head -c 120
echo
LEFT=$(curl -s "${hdr[@]}" -X POST "$URL/functions/v1/sync-captures" \
  -d "{\"installId\":\"$INSTALL\",\"deviceSecret\":\"$SECRET\"}" | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('captures',[])))")
echo "   captures remaining for this throwaway install: $LEFT"

say "$([ $RESULT -eq 0 ] && echo 'RESULT: PASS — no raw PII survived the deployed sanitizer' || echo 'RESULT: FAIL — see leaks above')"
exit $RESULT
