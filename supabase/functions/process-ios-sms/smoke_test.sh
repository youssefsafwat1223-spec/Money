#!/usr/bin/env bash
# Smoke test for process-ios-sms edge function.
#
# Required env vars (set before running):
#   SUPABASE_URL        e.g. https://xxxx.supabase.co
#   SUPABASE_ANON_KEY   anon/public key
#   TEST_INSTALL_ID     installId of a registered test device
#   TEST_DEVICE_SECRET  deviceSecret for that device
#
# Does NOT touch production user data — all payloadIds use prefix "smoke_test_"
# which can be cleaned up with:
#   DELETE FROM processed_captures WHERE payload_id LIKE 'smoke_test_%';

set -euo pipefail

BASE_URL="${SUPABASE_URL:?set SUPABASE_URL}/functions/v1/process-ios-sms"
ANON_KEY="${SUPABASE_ANON_KEY:?set SUPABASE_ANON_KEY}"
INSTALL_ID="${TEST_INSTALL_ID:?set TEST_INSTALL_ID}"
DEVICE_SECRET="${TEST_DEVICE_SECRET:?set TEST_DEVICE_SECRET}"

pass=0; fail=0

run_case() {
  local name="$1" payload_id="$2" sms_text="$3" sender="$4"
  local expect_parsed="${5:-true}" expect_amount="${6:-}" expect_currency="${7:-}"

  local body
  body=$(jq -n \
    --arg payloadId  "$payload_id" \
    --arg installId  "$INSTALL_ID" \
    --arg deviceSecret "$DEVICE_SECRET" \
    --arg smsText    "$sms_text" \
    --arg sanitizedText "$sms_text" \
    --arg sender     "$sender" \
    '{payloadId:$payloadId, installId:$installId, deviceSecret:$deviceSecret,
      smsText:$smsText, sanitizedText:$sanitizedText, sender:$sender, allowAi:false}')

  local resp http_status
  resp=$(curl -s -w '\n%{http_code}' -X POST "$BASE_URL" \
    -H "Content-Type: application/json" \
    -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $ANON_KEY" \
    -d "$body")
  http_status=$(echo "$resp" | tail -1)
  local body_json
  body_json=$(echo "$resp" | head -n -1)

  local status parsed_amount parsed_currency push_sent
  status=$(echo "$body_json" | jq -r '.capture.status // "none"')
  parsed_amount=$(echo "$body_json" | jq -r '.capture.parsed.amount // "null"')
  parsed_currency=$(echo "$body_json" | jq -r '.capture.parsed.currency // "null"')
  push_sent=$(echo "$body_json" | jq -r '.pushSent // false')

  local ok=true
  [[ "$http_status" != "200" ]] && ok=false
  [[ "$expect_parsed" == "true" && "$status" == "rejected" ]] && ok=false
  [[ -n "$expect_amount" && "$parsed_amount" != "$expect_amount" ]] && ok=false
  [[ -n "$expect_currency" && "$parsed_currency" != "$expect_currency" ]] && ok=false

  if [[ "$ok" == "true" ]]; then
    echo "  PASS  $name (HTTP $http_status | status=$status | amount=$parsed_amount $parsed_currency | pushSent=$push_sent)"
    ((pass++))
  else
    echo "  FAIL  $name (HTTP $http_status | status=$status | amount=$parsed_amount $parsed_currency | body=$body_json)"
    ((fail++))
  fi
}

echo "=== process-ios-sms smoke test ==="
echo ""

echo "--- 1. QNB Egypt debit ---"
run_case "QNB debit" \
  "smoke_test_qnb_debit_$(date +%s)" \
  "تم خصم EGP 100.00 من حسابك بتاريخ 01/07/2026 لدى FAWRY" \
  "QNB-EGYPT" true "100" "EGP"

echo "--- 2. QNB Egypt credit ---"
run_case "QNB credit" \
  "smoke_test_qnb_credit_$(date +%s)" \
  "تم إيداع EGP 5000.00 في حسابك بتاريخ 01/07/2026" \
  "QNB-EGYPT" true "5000" "EGP"

echo "--- 3. Fawry payment ---"
run_case "Fawry payment" \
  "smoke_test_fawry_$(date +%s)" \
  "تم خصم 45.50 EGP من بطاقتك 4907 عند FAWRY*BILL" \
  "Fawry" true "45.5" "EGP"

echo "--- 4. Unknown/unsupported bank SMS ---"
run_case "Unknown bank" \
  "smoke_test_unknown_$(date +%s)" \
  "Dear customer, your account has been updated successfully." \
  "UNKNOWN-BANK" false "" ""

echo "--- 5. Malformed SMS ---"
run_case "Malformed SMS" \
  "smoke_test_malformed_$(date +%s)" \
  "??!!! @@##" \
  "GARBAGE" false "" ""

echo "--- 6a. Duplicate payloadId — first submission ---"
DUPE_ID="smoke_test_dupe_$(date +%s)"
run_case "Dupe first" "$DUPE_ID" \
  "تم خصم EGP 50.00 من حسابك لدى STARBUCKS" \
  "CIB" true "50" "EGP"

echo "--- 6b. Duplicate payloadId — second submission (must be idempotent) ---"
resp2=$(curl -s -X POST "$BASE_URL" \
  -H "Content-Type: application/json" \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $ANON_KEY" \
  -d "$(jq -n \
    --arg pid "$DUPE_ID" --arg ii "$INSTALL_ID" --arg ds "$DEVICE_SECRET" \
    '{payloadId:$pid,installId:$ii,deviceSecret:$ds,
      smsText:"تم خصم EGP 50.00 من حسابك لدى STARBUCKS",
      sanitizedText:"تم خصم EGP 50.00 من حسابك لدى STARBUCKS",
      sender:"CIB",allowAi:false}')")
idempotent=$(echo "$resp2" | jq -r '.idempotent // false')
if [[ "$idempotent" == "true" ]]; then
  echo "  PASS  Duplicate idempotent (idempotent=$idempotent)"
  ((pass++))
else
  echo "  FAIL  Duplicate not idempotent (response=$resp2)"
  ((fail++))
fi

echo ""
echo "=== Results: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
