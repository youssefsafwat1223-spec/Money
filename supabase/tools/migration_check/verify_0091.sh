#!/usr/bin/env bash
# STEP 0.1 — verify migration 0091 against an ISOLATED throwaway Postgres.
#
# Scope, stated honestly:
#   * This exercises 0091's EFFECT on the real seeded rows: the exact
#     `sms_parsers` DDL from 0002 and the exact 12-rule INSERT replayed from
#     0002, then 0091 verbatim.
#   * It does NOT replay the full 91-migration chain. 0091 has no dependency
#     beyond the table existing, so the chain would add runtime, not coverage.
#   * It touches NO shared database. It runs in its own container on port 55433
#     and is torn down at the end. The `labibe_test_pg` container belonging to
#     another session is never contacted.
set -euo pipefail

CT=mali_mig_test_0091
DB=mali_0091
PSQL="docker exec -i $CT psql -v ON_ERROR_STOP=1 -U postgres"
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"

echo "=== fresh database ==="
$PSQL -c "DROP DATABASE IF EXISTS $DB;" >/dev/null
$PSQL -c "CREATE DATABASE $DB;" >/dev/null
PSQLDB="docker exec -i $CT psql -v ON_ERROR_STOP=1 -U postgres -d $DB"

echo "=== schema (sms_parsers DDL as in 0002) ==="
$PSQLDB <<'SQL' >/dev/null
CREATE TABLE IF NOT EXISTS sms_parsers (
  id                 UUID PRIMARY KEY,
  bank_id            UUID NOT NULL,
  sender_pattern     TEXT NOT NULL,
  message_pattern    TEXT NOT NULL,
  transaction_type   TEXT NOT NULL CHECK (transaction_type IN ('debit','credit','balance_inquiry')),
  language           TEXT NOT NULL CHECK (language IN ('ar','en','ar_en')),
  priority           INT NOT NULL DEFAULT 0,
  extracted_fields   JSONB NOT NULL DEFAULT '{}'::jsonb,
  is_active          BOOLEAN NOT NULL DEFAULT true,
  is_deleted         BOOLEAN NOT NULL DEFAULT false,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL

echo "=== seed the exact 12 rules from 0002 ==="
$PSQLDB < "$(dirname "$0")/seed_0002_rules.sql" >/dev/null
$PSQLDB -tAc "SELECT 'seeded rules: '||count(*) FROM sms_parsers;"

echo
echo "=== BEFORE: rules carrying the {1,2} decimal cap ==="
$PSQLDB -tAc "SELECT count(*) FROM sms_parsers WHERE strpos(message_pattern, '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)') > 0;" \
  | sed 's/^/  amount groups at {1,2}: /'
$PSQLDB -tAc "SELECT count(*) FROM sms_parsers WHERE strpos(message_pattern, '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)') > 0;" \
  | sed 's/^/  amount groups at {1,3}: /'

echo
echo "=== APPLY 0091 ==="
$PSQLDB < "$REPO/supabase/migrations/0091_catalog_amount_decimal_scale.sql"

echo
echo "=== AFTER ==="
$PSQLDB -tAc "SELECT count(*) FROM sms_parsers WHERE strpos(message_pattern, '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)') > 0;" \
  | sed 's/^/  amount groups now {1,3}: /'
$PSQLDB -tAc "SELECT count(*) FROM sms_parsers WHERE strpos(message_pattern, '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)') > 0;" \
  | sed 's/^/  amount groups still {1,2}: /'
$PSQLDB -tAc "SELECT count(*) FROM sms_parsers WHERE strpos(message_pattern, '[0-9]{1,2}') > 0;" \
  | sed 's/^/  ANY remaining {1,2} anywhere: /'

echo
echo "=== per-rule proof (sender -> amount quantifier) ==="
$PSQLDB -tAc "
SELECT rpad(regexp_replace(sender_pattern,'[\\^\$()]','','g'), 34)
       || CASE
            WHEN strpos(message_pattern, '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)') > 0 THEN '{1,3} OK'
            WHEN strpos(message_pattern, '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)') > 0 THEN '{1,2} NOT UPDATED'
            ELSE 'no standard amount group'
          END
FROM sms_parsers ORDER BY sender_pattern;" | sed 's/^/  /'

echo
echo "=== IDEMPOTENCY: apply 0091 a second time ==="
BEFORE_HASH=$($PSQLDB -tAc "SELECT md5(string_agg(message_pattern, '|' ORDER BY id)) FROM sms_parsers;")
$PSQLDB < "$REPO/supabase/migrations/0091_catalog_amount_decimal_scale.sql" >/dev/null
AFTER_HASH=$($PSQLDB -tAc "SELECT md5(string_agg(message_pattern, '|' ORDER BY id)) FROM sms_parsers;")
if [ "$BEFORE_HASH" = "$AFTER_HASH" ]; then
  echo "  IDEMPOTENT: second apply changed nothing ($BEFORE_HASH)"
else
  echo "  !! NOT IDEMPOTENT: $BEFORE_HASH -> $AFTER_HASH"; exit 1
fi

echo
echo "=== ROLLBACK / FORWARD ==="
# 0091 has no down-migration, which is correct: it widens an accepted set, so it
# is forward-compatible with any client. The reverse operation is nonetheless
# well-defined and is exercised here so the behaviour is known rather than
# assumed.
$PSQLDB -c "
UPDATE sms_parsers
SET message_pattern = replace(message_pattern,
      '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)',
      '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)'),
    updated_at = now()
WHERE strpos(message_pattern, '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)') > 0;" >/dev/null
REVERTED=$($PSQLDB -tAc "SELECT count(*) FROM sms_parsers WHERE strpos(message_pattern, '(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)') > 0;")
echo "  reverse applied -> rules back at {1,2}: $REVERTED"
$PSQLDB < "$REPO/supabase/migrations/0091_catalog_amount_decimal_scale.sql" >/dev/null
REFWD=$($PSQLDB -tAc "SELECT md5(string_agg(message_pattern, '|' ORDER BY id)) FROM sms_parsers;")
if [ "$REFWD" = "$AFTER_HASH" ]; then
  echo "  RE-FORWARD reproduces the post-0091 state exactly ($REFWD)"
else
  echo "  !! re-forward diverged"; exit 1
fi

echo
echo "=== teardown ==="
$PSQL -c "DROP DATABASE $DB;" >/dev/null
echo "  dropped $DB (container $CT left running for inspection; remove with: docker rm -f $CT)"
