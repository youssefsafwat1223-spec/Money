INSERT INTO sms_parsers (
  id, bank_id, sender_pattern, message_pattern, transaction_type, language,
  priority, extracted_fields, is_active, is_deleted, updated_at
)
SELECT
  id::uuid, bank_id::uuid, sender_pattern, message_pattern, transaction_type,
  language, priority, extracted_fields, is_active, is_deleted, updated_at
FROM jsonb_to_recordset($catalog_parsers$[
  {
    "id": "10000000-0000-4000-8000-000000000001",
    "bank_id": "00000000-0000-4000-8000-000000000001",
    "sender_pattern": "^(NBE|National Bank|NBE Alerts)$",
    "message_pattern": "[\\s\\S]*(?:خصم|شراء|سحب|Purchase|Debit)[\\s\\S]*?(?<currency>EGP|جنيه|ج\\.م)?\\s*(?<amount>[0-9][0-9,]*(?:\\.[0-9]{1,2})?)[\\s\\S]*?(?:لدى|At|Merchant)\\s*:?[ ]*(?<merchant>[^\\n]+)?",
    "transaction_type": "debit",
    "language": "ar_en",
    "priority": 100,
    "extracted_fields": {
      "amount": "amount",
      "currency": "currency",
      "merchant": "merchant",
      "type": "debit",
      "balance": "balance"
    },
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "10000000-0000-4000-8000-000000000002",
    "bank_id": "00000000-0000-4000-8000-000000000002",
    "sender_pattern": "^(CIB|CIB Alerts)$",
    "message_pattern": "[\\s\\S]*(?:Purchase|Debit|شراء|خصم)[\\s\\S]*?(?<currency>EGP|جنيه|ج\\.م)?\\s*(?<amount>[0-9][0-9,]*(?:\\.[0-9]{1,2})?)[\\s\\S]*?(?:At|لدى|Merchant)\\s*:?[ ]*(?<merchant>[^\\n]+)?",
    "transaction_type": "debit",
    "language": "ar_en",
    "priority": 100,
    "extracted_fields": {
      "amount": "amount",
      "currency": "currency",
      "merchant": "merchant",
      "type": "debit",
      "balance": "balance"
    },
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "10000000-0000-4000-8000-000000000003",
    "bank_id": "00000000-0000-4000-8000-000000000003",
    "sender_pattern": "^(Banque Misr|BM)$",
    "message_pattern": "[\\s\\S]*(?:خصم|شراء|Debit|Purchase)[\\s\\S]*?(?<amount>[0-9][0-9,]*(?:\\.[0-9]{1,2})?)\\s*(?<currency>EGP|جنيه|ج\\.م)?[\\s\\S]*?(?:لدى|At|Merchant)\\s*:?[ ]*(?<merchant>[^\\n]+)?",
    "transaction_type": "debit",
    "language": "ar_en",
    "priority": 90,
    "extracted_fields": {
      "amount": "amount",
      "currency": "currency",
      "merchant": "merchant",
      "type": "debit"
    },
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "10000000-0000-4000-8000-000000000004",
    "bank_id": "00000000-0000-4000-8000-000000000004",
    "sender_pattern": "^(QNB|QNB ALAHLI|QNB AlAhli)$",
    "message_pattern": "[\\s\\S]*(?:خصم|شراء|Debit|Purchase)[\\s\\S]*?(?<currency>EGP|جنيه|ج\\.م)?\\s*(?<amount>[0-9][0-9,]*(?:\\.[0-9]{1,2})?)[\\s\\S]*?(?:لدى|At|Merchant)\\s*:?[ ]*(?<merchant>[^\\n]+)?",
    "transaction_type": "debit",
    "language": "ar_en",
    "priority": 90,
    "extracted_fields": {
      "amount": "amount",
      "currency": "currency",
      "merchant": "merchant",
      "type": "debit"
    },
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "10000000-0000-4000-8000-000000000005",
    "bank_id": "00000000-0000-4000-8000-000000000005",
    "sender_pattern": "^(Vodafone Cash|VF-Cash|Vodafone)$",
    "message_pattern": "[\\s\\S]*(?:دفعت|خصم|سحب|Paid|Debit)[\\s\\S]*?(?<amount>[0-9][0-9,]*(?:\\.[0-9]{1,2})?)\\s*(?<currency>EGP|جنيه|ج\\.م)?[\\s\\S]*?(?:لدى|to|At)\\s*:?[ ]*(?<merchant>[^\\n]+)?",
    "transaction_type": "debit",
    "language": "ar_en",
    "priority": 80,
    "extracted_fields": {
      "amount": "amount",
      "currency": "currency",
      "merchant": "merchant",
      "type": "debit"
    },
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "10000000-0000-4000-8000-000000000006",
    "bank_id": "00000000-0000-4000-8000-000000000006",
    "sender_pattern": "^(Orange Money|Orange)$",
    "message_pattern": "[\\s\\S]*(?:دفعت|خصم|Paid|Debit)[\\s\\S]*?(?<amount>[0-9][0-9,]*(?:\\.[0-9]{1,2})?)\\s*(?<currency>EGP|جنيه|ج\\.م)?[\\s\\S]*?(?:لدى|to|At)\\s*:?[ ]*(?<merchant>[^\\n]+)?",
    "transaction_type": "debit",
    "language": "ar_en",
    "priority": 70,
    "extracted_fields": {
      "amount": "amount",
      "currency": "currency",
      "merchant": "merchant",
      "type": "debit"
    },
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "10000000-0000-4000-8000-000000000007",
    "bank_id": "00000000-0000-4000-8000-000000000007",
    "sender_pattern": "^(Etisalat Cash|Etisalat)$",
    "message_pattern": "[\\s\\S]*(?:دفعت|خصم|Paid|Debit)[\\s\\S]*?(?<amount>[0-9][0-9,]*(?:\\.[0-9]{1,2})?)\\s*(?<currency>EGP|جنيه|ج\\.م)?[\\s\\S]*?(?:لدى|to|At)\\s*:?[ ]*(?<merchant>[^\\n]+)?",
    "transaction_type": "debit",
    "language": "ar_en",
    "priority": 70,
    "extracted_fields": {
      "amount": "amount",
      "currency": "currency",
      "merchant": "merchant",
      "type": "debit"
    },
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "10000000-0000-4000-8000-000000000008",
    "bank_id": "00000000-0000-4000-8000-000000000008",
    "sender_pattern": "^(Fawry|myFawry)$",
    "message_pattern": "[\\s\\S]*(?:دفعت|خصم|Paid|Debit)[\\s\\S]*?(?<amount>[0-9][0-9,]*(?:\\.[0-9]{1,2})?)\\s*(?<currency>EGP|جنيه|ج\\.م)?[\\s\\S]*?(?:لدى|to|At)\\s*:?[ ]*(?<merchant>[^\\n]+)?",
    "transaction_type": "debit",
    "language": "ar_en",
    "priority": 60,
    "extracted_fields": {
      "amount": "amount",
      "currency": "currency",
      "merchant": "merchant",
      "type": "debit"
    },
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "10000000-0000-4000-8000-000000000101",
    "bank_id": "00000000-0000-4000-8000-000000000101",
    "sender_pattern": "^(SNB|AlAhli|Al Ahli)$",
    "message_pattern": "[\\s\\S]*(?:شراء|دفع|Purchase|Payment)[\\s\\S]*?(?:SAR|ريال|ر\\.س)?\\s*(?<amount>[0-9][0-9,]*(?:\\.[0-9]{1,2})?)[\\s\\S]*?(?:لدى|At)\\s*:?[ ]*(?<merchant>[^\\n]+)?",
    "transaction_type": "debit",
    "language": "ar_en",
    "priority": 100,
    "extracted_fields": {
      "amount": "amount",
      "currency": "SAR",
      "merchant": "merchant",
      "type": "debit",
      "balance": "balance"
    },
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "10000000-0000-4000-8000-000000000102",
    "bank_id": "00000000-0000-4000-8000-000000000102",
    "sender_pattern": "^(Rajhi|AlRajhi)$",
    "message_pattern": "[\\s\\S]*(?:شراء|دفع|Purchase|Payment)[\\s\\S]*?(?:SAR|ريال|ر\\.س)?\\s*(?<amount>[0-9][0-9,]*(?:\\.[0-9]{1,2})?)[\\s\\S]*?(?:لدى|At)\\s*:?[ ]*(?<merchant>[^\\n]+)?",
    "transaction_type": "debit",
    "language": "ar_en",
    "priority": 90,
    "extracted_fields": {
      "amount": "amount",
      "currency": "SAR",
      "merchant": "merchant",
      "type": "debit"
    },
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "10000000-0000-4000-8000-000000000103",
    "bank_id": "00000000-0000-4000-8000-000000000103",
    "sender_pattern": "^(Riyad)$",
    "message_pattern": "[\\s\\S]*(?:شراء|دفع|Purchase|Payment)[\\s\\S]*?(?:SAR|ريال|ر\\.س)?\\s*(?<amount>[0-9][0-9,]*(?:\\.[0-9]{1,2})?)[\\s\\S]*?(?:لدى|At)\\s*:?[ ]*(?<merchant>[^\\n]+)?",
    "transaction_type": "debit",
    "language": "ar_en",
    "priority": 80,
    "extracted_fields": {
      "amount": "amount",
      "currency": "SAR",
      "merchant": "merchant",
      "type": "debit"
    },
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "10000000-0000-4000-8000-000000000104",
    "bank_id": "00000000-0000-4000-8000-000000000104",
    "sender_pattern": "^(STCPay|STC Pay)$",
    "message_pattern": "[\\s\\S]*(?:الدفع|دفعت|Paid|Payment)[\\s\\S]*?(?<amount>[0-9][0-9,]*(?:\\.[0-9]{1,2})?)\\s*(?:SAR|ريال|ر\\.س)?[\\s\\S]*?(?:لدى|At)\\s*:?[ ]*(?<merchant>[^\\n]+)?",
    "transaction_type": "debit",
    "language": "ar_en",
    "priority": 80,
    "extracted_fields": {
      "amount": "amount",
      "currency": "SAR",
      "merchant": "merchant",
      "type": "debit"
    },
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  }
]$catalog_parsers$::jsonb) AS x(
  id text,
  bank_id text,
  sender_pattern text,
  message_pattern text,
  transaction_type text,
  language text,
  priority int,
  extracted_fields jsonb,
  is_active boolean,
  is_deleted boolean,
  updated_at timestamptz
)
ON CONFLICT (id) DO UPDATE SET
  bank_id = EXCLUDED.bank_id,
  sender_pattern = EXCLUDED.sender_pattern,
  message_pattern = EXCLUDED.message_pattern,
  transaction_type = EXCLUDED.transaction_type,
  language = EXCLUDED.language,
  priority = EXCLUDED.priority,
  extracted_fields = EXCLUDED.extracted_fields,
  is_active = EXCLUDED.is_active,
  is_deleted = EXCLUDED.is_deleted,
  updated_at = EXCLUDED.updated_at;
