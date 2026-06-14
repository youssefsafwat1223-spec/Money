-- Dynamic catalog MVP infrastructure.
-- Mirrors app/assets/catalog seed data and provides item-level delta versions.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SEQUENCE IF NOT EXISTS catalog_seq_banks;
CREATE SEQUENCE IF NOT EXISTS catalog_seq_parsers;
CREATE SEQUENCE IF NOT EXISTS catalog_seq_currencies;
CREATE SEQUENCE IF NOT EXISTS catalog_seq_countries;
CREATE SEQUENCE IF NOT EXISTS catalog_seq_categories;

CREATE TABLE IF NOT EXISTS catalog_versions (
  category    TEXT PRIMARY KEY,
  version     BIGINT NOT NULL DEFAULT 0,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO catalog_versions (category) VALUES
  ('banks'), ('parsers'), ('currencies'), ('countries'), ('categories')
ON CONFLICT (category) DO NOTHING;

CREATE TABLE IF NOT EXISTS banks (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name_ar              TEXT NOT NULL,
  name_en              TEXT NOT NULL,
  short_code           TEXT UNIQUE NOT NULL,
  logo_url             TEXT,
  country_code         TEXT NOT NULL,
  sms_senders          JSONB NOT NULL DEFAULT '[]'::jsonb,
  supported_currencies JSONB NOT NULL DEFAULT '[]'::jsonb,
  color_hex            TEXT,
  is_active            BOOLEAN NOT NULL DEFAULT true,
  sort_order           INT NOT NULL DEFAULT 0,
  is_deleted           BOOLEAN NOT NULL DEFAULT false,
  created_version      BIGINT NOT NULL DEFAULT 0,
  updated_version      BIGINT NOT NULL DEFAULT 0,
  deleted_version      BIGINT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION trg_version_banks() RETURNS TRIGGER AS $$
DECLARE v BIGINT;
BEGIN
  v := nextval('catalog_seq_banks');
  IF TG_OP = 'INSERT' THEN
    NEW.created_version := v;
    NEW.updated_version := v;
  ELSIF TG_OP = 'UPDATE' THEN
    NEW.updated_version := v;
    IF NEW.is_deleted AND NOT OLD.is_deleted THEN
      NEW.deleted_version := v;
    END IF;
  END IF;
  NEW.updated_at := now();
  UPDATE catalog_versions SET version = v, updated_at = now() WHERE category = 'banks';
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_banks_version ON banks;
CREATE TRIGGER trg_banks_version
  BEFORE INSERT OR UPDATE ON banks
  FOR EACH ROW EXECUTE FUNCTION trg_version_banks();

ALTER TABLE banks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS banks_anon_select ON banks;
CREATE POLICY banks_anon_select ON banks
  FOR SELECT TO anon USING (true);

CREATE TABLE IF NOT EXISTS sms_parsers (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bank_id            UUID NOT NULL REFERENCES banks(id),
  sender_pattern     TEXT NOT NULL,
  message_pattern    TEXT NOT NULL,
  transaction_type   TEXT NOT NULL CHECK (transaction_type IN ('debit','credit','balance_inquiry')),
  language           TEXT NOT NULL CHECK (language IN ('ar','en','ar_en')),
  priority           INT NOT NULL DEFAULT 0,
  extracted_fields   JSONB NOT NULL DEFAULT '{}'::jsonb,
  is_active          BOOLEAN NOT NULL DEFAULT true,
  is_deleted         BOOLEAN NOT NULL DEFAULT false,
  created_version    BIGINT NOT NULL DEFAULT 0,
  updated_version    BIGINT NOT NULL DEFAULT 0,
  deleted_version    BIGINT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION trg_version_parsers() RETURNS TRIGGER AS $$
DECLARE v BIGINT;
BEGIN
  v := nextval('catalog_seq_parsers');
  IF TG_OP = 'INSERT' THEN
    NEW.created_version := v;
    NEW.updated_version := v;
  ELSIF TG_OP = 'UPDATE' THEN
    NEW.updated_version := v;
    IF NEW.is_deleted AND NOT OLD.is_deleted THEN
      NEW.deleted_version := v;
    END IF;
  END IF;
  NEW.updated_at := now();
  UPDATE catalog_versions SET version = v, updated_at = now() WHERE category = 'parsers';
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_parsers_version ON sms_parsers;
CREATE TRIGGER trg_parsers_version
  BEFORE INSERT OR UPDATE ON sms_parsers
  FOR EACH ROW EXECUTE FUNCTION trg_version_parsers();

ALTER TABLE sms_parsers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sms_parsers_anon_select ON sms_parsers;
CREATE POLICY sms_parsers_anon_select ON sms_parsers
  FOR SELECT TO anon USING (true);

CREATE TABLE IF NOT EXISTS currencies (
  code            TEXT PRIMARY KEY,
  name_ar         TEXT NOT NULL,
  name_en         TEXT NOT NULL,
  symbol          TEXT NOT NULL,
  decimal_places  INT NOT NULL DEFAULT 2,
  country_codes   JSONB NOT NULL DEFAULT '[]'::jsonb,
  is_active       BOOLEAN NOT NULL DEFAULT true,
  is_deleted      BOOLEAN NOT NULL DEFAULT false,
  created_version BIGINT NOT NULL DEFAULT 0,
  updated_version BIGINT NOT NULL DEFAULT 0,
  deleted_version BIGINT,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION trg_version_currencies() RETURNS TRIGGER AS $$
DECLARE v BIGINT;
BEGIN
  v := nextval('catalog_seq_currencies');
  IF TG_OP = 'INSERT' THEN
    NEW.created_version := v;
    NEW.updated_version := v;
  ELSIF TG_OP = 'UPDATE' THEN
    NEW.updated_version := v;
    IF NEW.is_deleted AND NOT OLD.is_deleted THEN
      NEW.deleted_version := v;
    END IF;
  END IF;
  NEW.updated_at := now();
  UPDATE catalog_versions SET version = v, updated_at = now() WHERE category = 'currencies';
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_currencies_version ON currencies;
CREATE TRIGGER trg_currencies_version
  BEFORE INSERT OR UPDATE ON currencies
  FOR EACH ROW EXECUTE FUNCTION trg_version_currencies();

ALTER TABLE currencies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS currencies_anon_select ON currencies;
CREATE POLICY currencies_anon_select ON currencies
  FOR SELECT TO anon USING (true);

CREATE TABLE IF NOT EXISTS countries (
  code            TEXT PRIMARY KEY,
  name_ar         TEXT NOT NULL,
  name_en         TEXT NOT NULL,
  flag_emoji      TEXT NOT NULL,
  phone_prefix    TEXT NOT NULL,
  is_supported    BOOLEAN NOT NULL DEFAULT false,
  is_active       BOOLEAN NOT NULL DEFAULT true,
  is_deleted      BOOLEAN NOT NULL DEFAULT false,
  created_version BIGINT NOT NULL DEFAULT 0,
  updated_version BIGINT NOT NULL DEFAULT 0,
  deleted_version BIGINT,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION trg_version_countries() RETURNS TRIGGER AS $$
DECLARE v BIGINT;
BEGIN
  v := nextval('catalog_seq_countries');
  IF TG_OP = 'INSERT' THEN
    NEW.created_version := v;
    NEW.updated_version := v;
  ELSIF TG_OP = 'UPDATE' THEN
    NEW.updated_version := v;
    IF NEW.is_deleted AND NOT OLD.is_deleted THEN
      NEW.deleted_version := v;
    END IF;
  END IF;
  NEW.updated_at := now();
  UPDATE catalog_versions SET version = v, updated_at = now() WHERE category = 'countries';
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_countries_version ON countries;
CREATE TRIGGER trg_countries_version
  BEFORE INSERT OR UPDATE ON countries
  FOR EACH ROW EXECUTE FUNCTION trg_version_countries();

ALTER TABLE countries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS countries_anon_select ON countries;
CREATE POLICY countries_anon_select ON countries
  FOR SELECT TO anon USING (true);

CREATE TABLE IF NOT EXISTS categories (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key             TEXT UNIQUE NOT NULL,
  name_ar         TEXT NOT NULL,
  name_en         TEXT NOT NULL,
  icon            TEXT NOT NULL,
  color_hex       TEXT NOT NULL,
  parent_key      TEXT REFERENCES categories(key),
  type            TEXT NOT NULL CHECK (type IN ('expense','income','transfer')),
  sort_order      INT NOT NULL DEFAULT 0,
  is_system       BOOLEAN NOT NULL DEFAULT false,
  is_active       BOOLEAN NOT NULL DEFAULT true,
  is_deleted      BOOLEAN NOT NULL DEFAULT false,
  created_version BIGINT NOT NULL DEFAULT 0,
  updated_version BIGINT NOT NULL DEFAULT 0,
  deleted_version BIGINT,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION trg_version_categories() RETURNS TRIGGER AS $$
DECLARE v BIGINT;
BEGIN
  v := nextval('catalog_seq_categories');
  IF TG_OP = 'INSERT' THEN
    NEW.created_version := v;
    NEW.updated_version := v;
  ELSIF TG_OP = 'UPDATE' THEN
    NEW.updated_version := v;
    IF NEW.is_deleted AND NOT OLD.is_deleted THEN
      NEW.deleted_version := v;
    END IF;
  END IF;
  NEW.updated_at := now();
  UPDATE catalog_versions SET version = v, updated_at = now() WHERE category = 'categories';
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_categories_version ON categories;
CREATE TRIGGER trg_categories_version
  BEFORE INSERT OR UPDATE ON categories
  FOR EACH ROW EXECUTE FUNCTION trg_version_categories();

ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS categories_anon_select ON categories;
CREATE POLICY categories_anon_select ON categories
  FOR SELECT TO anon USING (true);

INSERT INTO banks (
  id, name_ar, name_en, short_code, logo_url, country_code, sms_senders,
  supported_currencies, color_hex, is_active, sort_order, is_deleted, updated_at
)
SELECT
  id::uuid, name_ar, name_en, short_code, logo_url, country_code,
  sms_senders, supported_currencies, color_hex, is_active, sort_order,
  is_deleted, updated_at
FROM jsonb_to_recordset($catalog_banks$[
  {
    "id": "00000000-0000-4000-8000-000000000001",
    "name_ar": "البنك الأهلي المصري",
    "name_en": "National Bank of Egypt",
    "short_code": "nbe",
    "logo_url": null,
    "country_code": "EG",
    "sms_senders": [
      "NBE",
      "National Bank",
      "NBE Alerts"
    ],
    "supported_currencies": [
      "EGP",
      "USD",
      "EUR",
      "GBP"
    ],
    "color_hex": "#0E7A3D",
    "is_active": true,
    "sort_order": 10,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "00000000-0000-4000-8000-000000000002",
    "name_ar": "البنك التجاري الدولي",
    "name_en": "Commercial International Bank",
    "short_code": "cib_eg",
    "logo_url": null,
    "country_code": "EG",
    "sms_senders": [
      "CIB",
      "CIB Alerts"
    ],
    "supported_currencies": [
      "EGP",
      "USD",
      "EUR",
      "GBP"
    ],
    "color_hex": "#1D4F91",
    "is_active": true,
    "sort_order": 20,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "00000000-0000-4000-8000-000000000003",
    "name_ar": "بنك مصر",
    "name_en": "Banque Misr",
    "short_code": "banque_misr",
    "logo_url": null,
    "country_code": "EG",
    "sms_senders": [
      "Banque Misr",
      "BM"
    ],
    "supported_currencies": [
      "EGP",
      "USD",
      "EUR"
    ],
    "color_hex": "#7A1F2B",
    "is_active": true,
    "sort_order": 30,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "00000000-0000-4000-8000-000000000004",
    "name_ar": "بنك قطر الوطني الأهلي",
    "name_en": "QNB Al Ahli",
    "short_code": "qnb_alahli",
    "logo_url": null,
    "country_code": "EG",
    "sms_senders": [
      "QNB",
      "QNB ALAHLI",
      "QNB AlAhli"
    ],
    "supported_currencies": [
      "EGP",
      "USD",
      "EUR"
    ],
    "color_hex": "#5C1A52",
    "is_active": true,
    "sort_order": 40,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "00000000-0000-4000-8000-000000000005",
    "name_ar": "فودافون كاش",
    "name_en": "Vodafone Cash",
    "short_code": "vodafone_cash",
    "logo_url": null,
    "country_code": "EG",
    "sms_senders": [
      "Vodafone Cash",
      "VF-Cash",
      "Vodafone"
    ],
    "supported_currencies": [
      "EGP"
    ],
    "color_hex": "#E60000",
    "is_active": true,
    "sort_order": 50,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "00000000-0000-4000-8000-000000000006",
    "name_ar": "أورنج موني",
    "name_en": "Orange Money",
    "short_code": "orange_money",
    "logo_url": null,
    "country_code": "EG",
    "sms_senders": [
      "Orange Money",
      "Orange"
    ],
    "supported_currencies": [
      "EGP"
    ],
    "color_hex": "#FF7900",
    "is_active": true,
    "sort_order": 60,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "00000000-0000-4000-8000-000000000007",
    "name_ar": "اتصالات كاش",
    "name_en": "Etisalat Cash",
    "short_code": "etisalat_cash",
    "logo_url": null,
    "country_code": "EG",
    "sms_senders": [
      "Etisalat Cash",
      "Etisalat"
    ],
    "supported_currencies": [
      "EGP"
    ],
    "color_hex": "#6AB344",
    "is_active": true,
    "sort_order": 70,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "00000000-0000-4000-8000-000000000008",
    "name_ar": "فوري",
    "name_en": "Fawry",
    "short_code": "fawry",
    "logo_url": null,
    "country_code": "EG",
    "sms_senders": [
      "Fawry",
      "myFawry"
    ],
    "supported_currencies": [
      "EGP"
    ],
    "color_hex": "#FFD200",
    "is_active": true,
    "sort_order": 80,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "00000000-0000-4000-8000-000000000101",
    "name_ar": "الأهلي السعودي",
    "name_en": "Saudi National Bank",
    "short_code": "snb",
    "logo_url": null,
    "country_code": "SA",
    "sms_senders": [
      "SNB",
      "AlAhli",
      "Al Ahli"
    ],
    "supported_currencies": [
      "SAR"
    ],
    "color_hex": "#006B54",
    "is_active": true,
    "sort_order": 10,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "00000000-0000-4000-8000-000000000102",
    "name_ar": "مصرف الراجحي",
    "name_en": "Al Rajhi Bank",
    "short_code": "alrajhi",
    "logo_url": null,
    "country_code": "SA",
    "sms_senders": [
      "Rajhi",
      "AlRajhi"
    ],
    "supported_currencies": [
      "SAR"
    ],
    "color_hex": "#113A7B",
    "is_active": true,
    "sort_order": 20,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "00000000-0000-4000-8000-000000000103",
    "name_ar": "بنك الرياض",
    "name_en": "Riyad Bank",
    "short_code": "riyad",
    "logo_url": null,
    "country_code": "SA",
    "sms_senders": [
      "Riyad"
    ],
    "supported_currencies": [
      "SAR"
    ],
    "color_hex": "#004B8D",
    "is_active": true,
    "sort_order": 30,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "00000000-0000-4000-8000-000000000104",
    "name_ar": "إس تي سي باي",
    "name_en": "STC Pay",
    "short_code": "stcpay",
    "logo_url": null,
    "country_code": "SA",
    "sms_senders": [
      "STCPay",
      "STC Pay"
    ],
    "supported_currencies": [
      "SAR"
    ],
    "color_hex": "#4F008C",
    "is_active": true,
    "sort_order": 40,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  }
]$catalog_banks$::jsonb) AS x(
  id text,
  name_ar text,
  name_en text,
  short_code text,
  logo_url text,
  country_code text,
  sms_senders jsonb,
  supported_currencies jsonb,
  color_hex text,
  is_active boolean,
  sort_order int,
  is_deleted boolean,
  updated_at timestamptz
)
ON CONFLICT (id) DO UPDATE SET
  name_ar = EXCLUDED.name_ar,
  name_en = EXCLUDED.name_en,
  short_code = EXCLUDED.short_code,
  logo_url = EXCLUDED.logo_url,
  country_code = EXCLUDED.country_code,
  sms_senders = EXCLUDED.sms_senders,
  supported_currencies = EXCLUDED.supported_currencies,
  color_hex = EXCLUDED.color_hex,
  is_active = EXCLUDED.is_active,
  sort_order = EXCLUDED.sort_order,
  is_deleted = EXCLUDED.is_deleted,
  updated_at = EXCLUDED.updated_at;

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

INSERT INTO currencies (
  code, name_ar, name_en, symbol, decimal_places, country_codes,
  is_active, is_deleted, updated_at
)
SELECT
  code, name_ar, name_en, symbol, decimal_places, country_codes,
  is_active, is_deleted, updated_at
FROM jsonb_to_recordset($catalog_currencies$[
  {
    "code": "EGP",
    "name_ar": "الجنيه المصري",
    "name_en": "Egyptian Pound",
    "symbol": "ج.م",
    "decimal_places": 2,
    "country_codes": [
      "EG"
    ],
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "SAR",
    "name_ar": "الريال السعودي",
    "name_en": "Saudi Riyal",
    "symbol": "ر.س",
    "decimal_places": 2,
    "country_codes": [
      "SA"
    ],
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "AED",
    "name_ar": "الدرهم الإماراتي",
    "name_en": "UAE Dirham",
    "symbol": "د.إ",
    "decimal_places": 2,
    "country_codes": [
      "AE"
    ],
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "USD",
    "name_ar": "الدولار الأمريكي",
    "name_en": "US Dollar",
    "symbol": "$",
    "decimal_places": 2,
    "country_codes": [
      "US",
      "EG",
      "SA",
      "AE"
    ],
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "EUR",
    "name_ar": "اليورو",
    "name_en": "Euro",
    "symbol": "€",
    "decimal_places": 2,
    "country_codes": [
      "EG",
      "SA",
      "AE"
    ],
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "GBP",
    "name_ar": "الجنيه الإسترليني",
    "name_en": "British Pound",
    "symbol": "£",
    "decimal_places": 2,
    "country_codes": [
      "GB",
      "EG",
      "SA",
      "AE"
    ],
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "KWD",
    "name_ar": "الدينار الكويتي",
    "name_en": "Kuwaiti Dinar",
    "symbol": "د.ك",
    "decimal_places": 3,
    "country_codes": [
      "KW"
    ],
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "QAR",
    "name_ar": "الريال القطري",
    "name_en": "Qatari Riyal",
    "symbol": "ر.ق",
    "decimal_places": 2,
    "country_codes": [
      "QA"
    ],
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "BHD",
    "name_ar": "الدينار البحريني",
    "name_en": "Bahraini Dinar",
    "symbol": "د.ب",
    "decimal_places": 3,
    "country_codes": [
      "BH"
    ],
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "OMR",
    "name_ar": "الريال العماني",
    "name_en": "Omani Rial",
    "symbol": "ر.ع",
    "decimal_places": 3,
    "country_codes": [
      "OM"
    ],
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "JOD",
    "name_ar": "الدينار الأردني",
    "name_en": "Jordanian Dinar",
    "symbol": "د.أ",
    "decimal_places": 3,
    "country_codes": [
      "JO"
    ],
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  }
]$catalog_currencies$::jsonb) AS x(
  code text,
  name_ar text,
  name_en text,
  symbol text,
  decimal_places int,
  country_codes jsonb,
  is_active boolean,
  is_deleted boolean,
  updated_at timestamptz
)
ON CONFLICT (code) DO UPDATE SET
  name_ar = EXCLUDED.name_ar,
  name_en = EXCLUDED.name_en,
  symbol = EXCLUDED.symbol,
  decimal_places = EXCLUDED.decimal_places,
  country_codes = EXCLUDED.country_codes,
  is_active = EXCLUDED.is_active,
  is_deleted = EXCLUDED.is_deleted,
  updated_at = EXCLUDED.updated_at;

INSERT INTO countries (
  code, name_ar, name_en, flag_emoji, phone_prefix, is_supported,
  is_active, is_deleted, updated_at
)
SELECT
  code, name_ar, name_en, flag_emoji, phone_prefix, is_supported,
  is_active, is_deleted, updated_at
FROM jsonb_to_recordset($catalog_countries$[
  {
    "code": "EG",
    "name_ar": "مصر",
    "name_en": "Egypt",
    "flag_emoji": "🇪🇬",
    "phone_prefix": "+20",
    "is_supported": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "SA",
    "name_ar": "السعودية",
    "name_en": "Saudi Arabia",
    "flag_emoji": "🇸🇦",
    "phone_prefix": "+966",
    "is_supported": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "AE",
    "name_ar": "الإمارات",
    "name_en": "United Arab Emirates",
    "flag_emoji": "🇦🇪",
    "phone_prefix": "+971",
    "is_supported": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "KW",
    "name_ar": "الكويت",
    "name_en": "Kuwait",
    "flag_emoji": "🇰🇼",
    "phone_prefix": "+965",
    "is_supported": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "QA",
    "name_ar": "قطر",
    "name_en": "Qatar",
    "flag_emoji": "🇶🇦",
    "phone_prefix": "+974",
    "is_supported": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "BH",
    "name_ar": "البحرين",
    "name_en": "Bahrain",
    "flag_emoji": "🇧🇭",
    "phone_prefix": "+973",
    "is_supported": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "OM",
    "name_ar": "عمان",
    "name_en": "Oman",
    "flag_emoji": "🇴🇲",
    "phone_prefix": "+968",
    "is_supported": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "JO",
    "name_ar": "الأردن",
    "name_en": "Jordan",
    "flag_emoji": "🇯🇴",
    "phone_prefix": "+962",
    "is_supported": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "US",
    "name_ar": "الولايات المتحدة",
    "name_en": "United States",
    "flag_emoji": "🇺🇸",
    "phone_prefix": "+1",
    "is_supported": false,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "code": "GB",
    "name_ar": "المملكة المتحدة",
    "name_en": "United Kingdom",
    "flag_emoji": "🇬🇧",
    "phone_prefix": "+44",
    "is_supported": false,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  }
]$catalog_countries$::jsonb) AS x(
  code text,
  name_ar text,
  name_en text,
  flag_emoji text,
  phone_prefix text,
  is_supported boolean,
  is_active boolean,
  is_deleted boolean,
  updated_at timestamptz
)
ON CONFLICT (code) DO UPDATE SET
  name_ar = EXCLUDED.name_ar,
  name_en = EXCLUDED.name_en,
  flag_emoji = EXCLUDED.flag_emoji,
  phone_prefix = EXCLUDED.phone_prefix,
  is_supported = EXCLUDED.is_supported,
  is_active = EXCLUDED.is_active,
  is_deleted = EXCLUDED.is_deleted,
  updated_at = EXCLUDED.updated_at;

INSERT INTO categories (
  id, key, name_ar, name_en, icon, color_hex, parent_key, type, sort_order,
  is_system, is_active, is_deleted, updated_at
)
SELECT
  id::uuid, key, name_ar, name_en, icon, color_hex, parent_key, type,
  sort_order, is_system, is_active, is_deleted, updated_at
FROM jsonb_to_recordset($catalog_categories$[
  {
    "id": "20000000-0000-4000-8000-000000000000",
    "key": "all_expenses",
    "name_ar": "كل المصروفات",
    "name_en": "All expenses",
    "icon": "wallet-cards",
    "color_hex": "#AB47BC",
    "parent_key": null,
    "type": "expense",
    "sort_order": -1,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000001",
    "key": "restaurants",
    "name_ar": "مطاعم",
    "name_en": "Restaurants",
    "icon": "utensils-crossed",
    "color_hex": "#FF7043",
    "parent_key": null,
    "type": "expense",
    "sort_order": 0,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000002",
    "key": "groceries",
    "name_ar": "بقالة",
    "name_en": "Groceries",
    "icon": "shopping-basket",
    "color_hex": "#43A047",
    "parent_key": null,
    "type": "expense",
    "sort_order": 1,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000003",
    "key": "transport",
    "name_ar": "مواصلات",
    "name_en": "Transport",
    "icon": "car-taxi-front",
    "color_hex": "#1E88E5",
    "parent_key": null,
    "type": "expense",
    "sort_order": 2,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000004",
    "key": "fuel",
    "name_ar": "وقود",
    "name_en": "Fuel",
    "icon": "fuel",
    "color_hex": "#5E35B1",
    "parent_key": null,
    "type": "expense",
    "sort_order": 3,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000005",
    "key": "bills",
    "name_ar": "فواتير",
    "name_en": "Bills",
    "icon": "receipt-text",
    "color_hex": "#546E7A",
    "parent_key": null,
    "type": "expense",
    "sort_order": 4,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000006",
    "key": "shopping",
    "name_ar": "تسوق",
    "name_en": "Shopping",
    "icon": "shopping-bag",
    "color_hex": "#8E24AA",
    "parent_key": null,
    "type": "expense",
    "sort_order": 5,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000007",
    "key": "health",
    "name_ar": "صحة",
    "name_en": "Health",
    "icon": "heart-pulse",
    "color_hex": "#E53935",
    "parent_key": null,
    "type": "expense",
    "sort_order": 6,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000008",
    "key": "education",
    "name_ar": "تعليم",
    "name_en": "Education",
    "icon": "graduation-cap",
    "color_hex": "#3949AB",
    "parent_key": null,
    "type": "expense",
    "sort_order": 7,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000009",
    "key": "entertainment",
    "name_ar": "ترفيه",
    "name_en": "Entertainment",
    "icon": "clapperboard",
    "color_hex": "#FB8C00",
    "parent_key": null,
    "type": "expense",
    "sort_order": 8,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000010",
    "key": "subscriptions",
    "name_ar": "اشتراكات",
    "name_en": "Subscriptions",
    "icon": "repeat",
    "color_hex": "#6D4C41",
    "parent_key": null,
    "type": "expense",
    "sort_order": 9,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000011",
    "key": "transfers",
    "name_ar": "تحويلات",
    "name_en": "Transfers",
    "icon": "arrow-left-right",
    "color_hex": "#00897B",
    "parent_key": null,
    "type": "transfer",
    "sort_order": 10,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000012",
    "key": "cash",
    "name_ar": "سحب نقدي",
    "name_en": "Cash",
    "icon": "banknote",
    "color_hex": "#7CB342",
    "parent_key": null,
    "type": "expense",
    "sort_order": 11,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000013",
    "key": "travel",
    "name_ar": "سفر",
    "name_en": "Travel",
    "icon": "plane",
    "color_hex": "#00ACC1",
    "parent_key": null,
    "type": "expense",
    "sort_order": 12,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000014",
    "key": "gifts",
    "name_ar": "هدايا",
    "name_en": "Gifts",
    "icon": "gift",
    "color_hex": "#D81B60",
    "parent_key": null,
    "type": "expense",
    "sort_order": 13,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000015",
    "key": "kids",
    "name_ar": "أطفال",
    "name_en": "Kids",
    "icon": "baby",
    "color_hex": "#F4511E",
    "parent_key": null,
    "type": "expense",
    "sort_order": 14,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000016",
    "key": "home",
    "name_ar": "منزل",
    "name_en": "Home",
    "icon": "house",
    "color_hex": "#8D6E63",
    "parent_key": null,
    "type": "expense",
    "sort_order": 15,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000017",
    "key": "cafes",
    "name_ar": "كافيهات",
    "name_en": "Cafes",
    "icon": "coffee",
    "color_hex": "#6D4C41",
    "parent_key": null,
    "type": "expense",
    "sort_order": 16,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000018",
    "key": "maintenance",
    "name_ar": "صيانة",
    "name_en": "Maintenance",
    "icon": "wrench",
    "color_hex": "#757575",
    "parent_key": null,
    "type": "expense",
    "sort_order": 17,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000019",
    "key": "income",
    "name_ar": "دخل",
    "name_en": "Income",
    "icon": "wallet-cards",
    "color_hex": "#00C853",
    "parent_key": null,
    "type": "income",
    "sort_order": 18,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  },
  {
    "id": "20000000-0000-4000-8000-000000000020",
    "key": "other",
    "name_ar": "أخرى",
    "name_en": "Other",
    "icon": "shapes",
    "color_hex": "#9E9E9E",
    "parent_key": null,
    "type": "expense",
    "sort_order": 19,
    "is_system": true,
    "is_active": true,
    "is_deleted": false,
    "updated_at": "2026-06-14T00:00:00.000Z"
  }
]$catalog_categories$::jsonb) AS x(
  id text,
  key text,
  name_ar text,
  name_en text,
  icon text,
  color_hex text,
  parent_key text,
  type text,
  sort_order int,
  is_system boolean,
  is_active boolean,
  is_deleted boolean,
  updated_at timestamptz
)
ON CONFLICT (id) DO UPDATE SET
  key = EXCLUDED.key,
  name_ar = EXCLUDED.name_ar,
  name_en = EXCLUDED.name_en,
  icon = EXCLUDED.icon,
  color_hex = EXCLUDED.color_hex,
  parent_key = EXCLUDED.parent_key,
  type = EXCLUDED.type,
  sort_order = EXCLUDED.sort_order,
  is_system = EXCLUDED.is_system,
  is_active = EXCLUDED.is_active,
  is_deleted = EXCLUDED.is_deleted,
  updated_at = EXCLUDED.updated_at;
