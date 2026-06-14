# Mali — Dynamic Catalog MVP: Codex Implementation Tasks

> **Instructions for Codex:**
> - Work through tasks in order within each phase. Do not start Phase 1 before Phase 0 is complete.
> - Mark each task `- [x]` only after it is fully implemented and verified.
> - Each task is self-contained. Read the constraints section before implementing anything.
> - Do not implement anything outside the listed tasks.
> - Do not modify parser business logic, security thresholds, OTP detection, or confidence scoring — those stay hardcoded.

---

## Critical Constraints (Read Before Any Implementation)

1. **The app always reads from local Drift DB. Never directly from network.**
   Sync writes to Drift. UI reads from Drift. No exceptions.

2. **Remote catalog = content only. Business logic stays in Dart.**
   Parser rules describe patterns. Decisions like "is this OTP?", "is confidence too low?", "ignore this sender?" stay hardcoded in the app.

3. **Regex must be Dart syntax.**
   Named capture groups use `(?<name>...)` — NOT Python-style `(?P<name>...)`.

4. **Parser runs in a Dart isolate with a 2-second timeout.**
   Protects against catastrophic backtracking from bad remote regex.

5. **Feature flag rollout uses SHA-256, not Dart `hashCode`.**
   `hashCode` is not stable across Dart versions/runs. Use `sha256("$installId:$flagKey").bytes → 16-bit int % 100`.

6. **Category system keys must be stable strings.**
   Categories have a `key TEXT UNIQUE` field (`'restaurants'`, `'subscriptions'`, etc.). Parser rules reference categories by `key`, not UUID.

7. **Supabase INSERT trigger uses one `nextval` call.**
   On INSERT: `v = nextval(seq)`, then `created_version = v` AND `updated_version = v`. Not two separate calls.

8. **No HMAC secret inside the app binary.**
   For MVP: HTTPS + Edge Function filtering is the security model. If tamper-proof signatures are needed later, use server private key + hardcoded public key in app.

9. **Safe defaults for all feature flags.**
   If sync fails, every flag falls back to a hardcoded safe default defined in Dart. Flags never have an "unknown" state.

10. **Bundled seed data is the last-resort fallback.**
    Seed JSON files ship inside the app at `assets/catalog/`. Applied once on first launch if Drift tables are empty.

---

## Phase 0 — Foundation

> Goal: Local infrastructure ready. No network calls yet.

### 0.1 — Drift Schema: `catalog_metadata` table

- [x] Add `catalog_metadata` table to `lib/data/db/app_database.dart`
- [x] Fields: `category TEXT PK`, `server_version INT`, `local_version INT`, `last_synced_at DATETIME nullable`, `etag TEXT nullable`
- [x] Categories (values for the `category` field): `'banks'`, `'parsers'`, `'currencies'`, `'countries'`
- [x] Write a Drift migration for this new table
- [x] Add a `CatalogMetadataDao` with methods: `getVersion(category)`, `upsertVersion(category, serverV, localV)`, `setLastSynced(category, DateTime)`

---

### 0.2 — Drift Schema: `remote_banks` table

- [x] Add `remote_banks` table to `app_database.dart`
- [x] Fields:
  ```
  id              TEXT PK
  name_ar         TEXT
  name_en         TEXT
  short_code      TEXT UNIQUE
  logo_url        TEXT nullable
  country_code    TEXT
  sms_senders     TEXT          -- JSON array string: '["NBE","02NBE"]'
  supported_currencies TEXT     -- JSON array string: '["EGP","USD"]'
  color_hex       TEXT nullable
  is_active       BOOLEAN
  sort_order      INT
  is_deleted      BOOLEAN DEFAULT false
  updated_at      DATETIME
  ```
- [x] Write Drift migration
- [x] Add `RemoteBanksDao` with: `upsertAll(List)`, `markDeleted(List<String> ids)`, `getActiveBanks(String countryCode)`, `getBankBySender(String sender)`

---

### 0.3 — Drift Schema: `remote_parsers` table

- [x] Add `remote_parsers` table
- [x] Fields:
  ```
  id                 TEXT PK
  bank_id            TEXT           -- FK → remote_banks.id
  sender_pattern     TEXT           -- Dart regex (?<name>...)
  message_pattern    TEXT           -- Dart regex (?<name>...)
  transaction_type   TEXT           -- 'debit' | 'credit' | 'balance_inquiry'
  language           TEXT           -- 'ar' | 'en' | 'ar_en'
  priority           INT
  extracted_fields   TEXT           -- JSON: {"amount":"amount","currency":"currency",...}
  is_active          BOOLEAN
  is_deleted         BOOLEAN DEFAULT false
  updated_at         DATETIME
  ```
- [x] Write Drift migration
- [x] Add `RemoteParsersDao` with: `upsertAll(List)`, `markDeleted(List<String> ids)`, `getActiveParsersByBankId(String bankId)`, `getAllActiveParsers()`

---

### 0.4 — Drift Schema: `remote_currencies` table

- [x] Add `remote_currencies` table
- [x] Fields:
  ```
  code             TEXT PK        -- ISO 4217: 'EGP', 'SAR', 'USD'
  name_ar          TEXT
  name_en          TEXT
  symbol           TEXT
  decimal_places   INT
  country_codes    TEXT           -- JSON array string
  is_active        BOOLEAN
  is_deleted       BOOLEAN DEFAULT false
  updated_at       DATETIME
  ```
- [x] Write Drift migration
- [x] Add `RemoteCurrenciesDao` with: `upsertAll(List)`, `getActiveCurrencies()`, `getCurrenciesForCountry(String countryCode)`

---

### 0.5 — Drift Schema: `remote_countries` table

- [x] Add `remote_countries` table
- [x] Fields:
  ```
  code             TEXT PK        -- ISO 3166-1 alpha-2: 'EG', 'SA', 'AE'
  name_ar          TEXT
  name_en          TEXT
  flag_emoji       TEXT
  phone_prefix     TEXT
  is_supported     BOOLEAN
  is_active        BOOLEAN
  is_deleted       BOOLEAN DEFAULT false
  updated_at       DATETIME
  ```
- [x] Write Drift migration
- [x] Add `RemoteCountriesDao` with: `upsertAll(List)`, `getSupportedCountries()`, `getByCode(String code)`

---

### 0.6 — Drift Schema: `remote_categories` table

- [x] Add `remote_categories` table
- [x] Fields:
  ```
  id               TEXT PK
  key              TEXT UNIQUE    -- stable string: 'restaurants', 'subscriptions', 'transport'
  name_ar          TEXT
  name_en          TEXT
  icon             TEXT           -- lucide icon name
  color_hex        TEXT
  parent_key       TEXT nullable  -- references key, not id
  type             TEXT           -- 'expense' | 'income' | 'transfer'
  sort_order       INT
  is_system        BOOLEAN        -- system categories cannot be deleted by user
  is_active        BOOLEAN
  is_deleted       BOOLEAN DEFAULT false
  updated_at       DATETIME
  ```
- [x] Write Drift migration
- [x] Add `RemoteCategoriesDao` with: `upsertAll(List)`, `markDeleted(List<String> ids)`, `getByKey(String key)`, `getActiveCategories()`, `getSystemCategories()`

---

### 0.7 — Seed JSON Files

- [x] Create directory `assets/catalog/` in the project root
- [x] Create `assets/catalog/banks.json` — array of bank objects matching `remote_banks` schema. Include at minimum: NBE, CIB, Banque Misr, QNB, Vodafone Cash, Orange Money, Etisalat Cash, Fawry. Use `"id"` as stable UUID strings.
- [x] Create `assets/catalog/parsers.json` — array of parser rule objects matching `remote_parsers` schema. Migrate any hardcoded rules from the existing `RulesClient` / `bank_rules` into this file. All regex must use Dart named group syntax `(?<name>...)`.
- [x] Create `assets/catalog/currencies.json` — include at minimum: EGP, SAR, AED, USD, EUR, GBP, KWD, QAR, BHD, OMR, JOD.
- [x] Create `assets/catalog/countries.json` — include at minimum: EG, SA, AE, KW, QA, BH, OM, JO, US, GB.
- [x] Create `assets/catalog/categories.json` — include all categories currently hardcoded in the app with their existing `key` strings. Do not change existing keys.
- [x] Register all files in `pubspec.yaml` under `flutter: assets:`

---

### 0.8 — Seed Loader Service

- [x] Create `lib/data/catalog/seed_loader.dart`
- [x] Class `SeedLoader` with method `Future<void> seedIfEmpty(AppDatabase db)`
- [x] On first launch (when all remote_* tables are empty): read each JSON file from assets, parse, and insert into the corresponding Drift table
- [x] Set `catalog_metadata` `local_version = 0` and `server_version = 0` for each category after seeding
- [x] Log which categories were seeded vs. skipped (already had data)
- [x] Call `SeedLoader.seedIfEmpty()` once during app startup, before the sync engine runs

---

## Phase 1 — Supabase Backend + Sync Engine

> Goal: Delta sync working for banks, parsers, currencies, countries, categories.

### 1.1 — Supabase: Sequence and Version Infrastructure

- [x] Create a Postgres sequence per catalog category:
  ```sql
  CREATE SEQUENCE catalog_seq_banks;
  CREATE SEQUENCE catalog_seq_parsers;
  CREATE SEQUENCE catalog_seq_currencies;
  CREATE SEQUENCE catalog_seq_countries;
  CREATE SEQUENCE catalog_seq_categories;
  ```
- [x] Create `catalog_versions` table:
  ```sql
  CREATE TABLE catalog_versions (
    category    TEXT PRIMARY KEY,
    version     BIGINT NOT NULL DEFAULT 0,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  INSERT INTO catalog_versions (category) VALUES
    ('banks'), ('parsers'), ('currencies'), ('countries'), ('categories');
  ```

---

### 1.2 — Supabase: `banks` Table

- [x] Create `banks` table:
  ```sql
  CREATE TABLE banks (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name_ar              TEXT NOT NULL,
    name_en              TEXT NOT NULL,
    short_code           TEXT UNIQUE NOT NULL,
    logo_url             TEXT,
    country_code         TEXT NOT NULL,
    sms_senders          JSONB NOT NULL DEFAULT '[]',
    supported_currencies JSONB NOT NULL DEFAULT '[]',
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
  ```
- [x] Create trigger on `banks` for versioning:
  ```sql
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
    UPDATE catalog_versions SET version = v, updated_at = now() WHERE category = 'banks';
    RETURN NEW;
  END;
  $$ LANGUAGE plpgsql;

  CREATE TRIGGER trg_banks_version
    BEFORE INSERT OR UPDATE ON banks
    FOR EACH ROW EXECUTE FUNCTION trg_version_banks();
  ```
- [x] Enable RLS on `banks`. Policy: `SELECT` for `anon` role, all writes blocked for `anon`.
- [x] Seed the table with the same banks from `assets/catalog/banks.json`. Use the same UUIDs.

---

### 1.3 — Supabase: `sms_parsers` Table

- [x] Create `sms_parsers` table (same version trigger pattern as banks):
  ```sql
  CREATE TABLE sms_parsers (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bank_id            UUID NOT NULL REFERENCES banks(id),
    sender_pattern     TEXT NOT NULL,
    message_pattern    TEXT NOT NULL,
    transaction_type   TEXT NOT NULL CHECK (transaction_type IN ('debit','credit','balance_inquiry')),
    language           TEXT NOT NULL CHECK (language IN ('ar','en','ar_en')),
    priority           INT NOT NULL DEFAULT 0,
    extracted_fields   JSONB NOT NULL DEFAULT '{}',
    is_active          BOOLEAN NOT NULL DEFAULT true,
    is_deleted         BOOLEAN NOT NULL DEFAULT false,
    created_version    BIGINT NOT NULL DEFAULT 0,
    updated_version    BIGINT NOT NULL DEFAULT 0,
    deleted_version    BIGINT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  ```
- [x] Create version trigger `trg_version_parsers` using `catalog_seq_parsers` and category `'parsers'`
- [x] Enable RLS: SELECT for anon, no writes for anon
- [x] Seed with parsers from `assets/catalog/parsers.json`

---

### 1.4 — Supabase: `currencies` Table

- [x] Create `currencies` table with same version trigger pattern using `catalog_seq_currencies`:
  ```sql
  CREATE TABLE currencies (
    code            TEXT PRIMARY KEY,
    name_ar         TEXT NOT NULL,
    name_en         TEXT NOT NULL,
    symbol          TEXT NOT NULL,
    decimal_places  INT NOT NULL DEFAULT 2,
    country_codes   JSONB NOT NULL DEFAULT '[]',
    is_active       BOOLEAN NOT NULL DEFAULT true,
    is_deleted      BOOLEAN NOT NULL DEFAULT false,
    created_version BIGINT NOT NULL DEFAULT 0,
    updated_version BIGINT NOT NULL DEFAULT 0,
    deleted_version BIGINT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  ```
- [x] Version trigger using `catalog_seq_currencies`, category `'currencies'`
- [x] RLS: SELECT for anon only
- [x] Seed from `assets/catalog/currencies.json`

---

### 1.5 — Supabase: `countries` Table

- [x] Create `countries` table with same version trigger pattern using `catalog_seq_countries`:
  ```sql
  CREATE TABLE countries (
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
  ```
- [x] Version trigger using `catalog_seq_countries`, category `'countries'`
- [x] RLS: SELECT for anon only
- [x] Seed from `assets/catalog/countries.json`

---

### 1.6 — Supabase: `categories` Table

- [x] Create `categories` table:
  ```sql
  CREATE TABLE categories (
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
  ```
- [x] Version trigger using `catalog_seq_categories`, category `'categories'`
- [x] RLS: SELECT for anon only
- [x] Seed from `assets/catalog/categories.json`

---

### 1.7 — Supabase: Edge Function `/catalog/versions`

- [x] Create Supabase Edge Function at `supabase/functions/catalog-versions/index.ts`
- [x] Reads `catalog_versions` table and returns all category versions as a flat JSON object:
  ```json
  { "banks": 42, "parsers": 71, "currencies": 5, "countries": 3, "categories": 8 }
  ```
- [x] No auth required (public, rate limited by Supabase)
- [x] Reads request header `X-App-Version` — logs it, does not filter by it at this endpoint

---

### 1.8 — Supabase: Edge Function `/catalog/delta`

- [x] Create Supabase Edge Function at `supabase/functions/catalog-delta/index.ts`
- [x] Accepts query params: `category`, `since_version`, `country` (optional)
- [x] Validates `category` is one of: `banks`, `parsers`, `currencies`, `countries`, `categories`
- [x] Queries the appropriate table for rows where `updated_version > since_version`
- [x] Separately queries for `deleted_ids`: rows where `deleted_version > since_version AND is_deleted = true`
- [x] Filters: `is_active = true` OR `is_deleted = true` (deleted items must be included for client cleanup)
- [x] If `country` param provided, filters `country_code = country` for banks, `country_codes @> '["country"]'` for currencies/countries
- [x] Returns:
  ```json
  {
    "meta": { "category": "banks", "version": 43, "since_version": 40 },
    "items": [...],
    "deleted_ids": ["uuid-1"]
  }
  ```
- [x] If `since_version = 0`, returns all active items (full load)
- [x] Reads `X-App-Version` header — reserves it for future filtering, logs it

---

### 1.9 — Dart: `CatalogSyncService`

- [x] Create `lib/data/catalog/catalog_sync_service.dart`
- [x] Class `CatalogSyncService` injected with: `AppDatabase`, `SupabaseClient`, `CatalogMetadataDao`
- [x] Method `Future<void> syncAll({String? countryCode})` — main entry point
- [x] Internal flow:
  1. Call `/catalog/versions` Edge Function
  2. Compare server versions with local versions from `catalog_metadata`
  3. For each stale category (server > local), call `/catalog/delta?category=X&since_version=N`
  4. Write results to Drift in a single transaction per category: upsert items, mark deleted_ids as `is_deleted = true`
  5. Update `catalog_metadata` with new version and `last_synced_at = DateTime.now()`
- [x] Method `Future<void> syncCategory(String category, {String? countryCode})`
- [x] All HTTP errors are caught and logged — sync failure must never crash the app
- [x] On network error: log, skip, app continues with existing local data
- [x] Parallel category fetches (use `Future.wait`)

---

### 1.10 — Dart: Sync Triggers

- [x] Call `SeedLoader.seedIfEmpty()` then `CatalogSyncService.syncAll()` during app cold start in `app_shell.dart` — run async, do not block UI
- [x] On app resume (from background): call `syncAll()` if `last_synced_at > 15 minutes ago`
- [x] Expose a `syncCatalog()` method that screens can call on pull-to-refresh
- [x] Create a Riverpod provider `catalogSyncServiceProvider` returning `CatalogSyncService`

---

### 1.11 — Dart: Wire Parser V2 + RulesClient to Drift

- [x] Update `RulesClient` (or equivalent) to load parser rules from `RemoteParsersDao.getAllActiveParsers()` instead of any hardcoded list
- [x] Update bank lookup to use `RemoteBanksDao.getBankBySender(sender)` for SMS sender matching
- [x] Parser execution must run in a Dart `Isolate` with a 2-second timeout. Kill isolate and return null on timeout.
- [x] Do NOT modify: OTP detection logic, confidence thresholds, pending rules, max generic confidence. These stay hardcoded.
- [x] Regex patterns from Drift are compiled to `RegExp` objects and cached in memory per app session (not recompiled on every SMS)

---

### 1.12 — Dart: Currency + Country Providers

- [x] Create Riverpod provider `activeCurrenciesProvider` → reads from `RemoteCurrenciesDao.getActiveCurrencies()`
- [x] Create Riverpod provider `supportedCountriesProvider` → reads from `RemoteCountriesDao.getSupportedCountries()`
- [x] Replace any hardcoded currency/country lists in the app with these providers
- [x] Existing `AccountEntity.currency` and currency formatting logic should remain unchanged — only the source of available currencies changes

---

## Phase 2 — Feature Flags + Announcements

> Goal: Remote feature gating and in-app announcements working.

### 2.1 — Supabase: `feature_flags` Table

- [x] Create `feature_flags` table:
  ```sql
  CREATE TABLE feature_flags (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key              TEXT UNIQUE NOT NULL,
    value_type       TEXT NOT NULL CHECK (value_type IN ('boolean','string','number','json')),
    value            TEXT NOT NULL,
    description      TEXT,
    rollout_percent  INT NOT NULL DEFAULT 100 CHECK (rollout_percent BETWEEN 0 AND 100),
    target_countries JSONB NOT NULL DEFAULT '[]',
    is_active        BOOLEAN NOT NULL DEFAULT true,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  ```
- [x] No version trigger needed — flags are always fetched in full (no delta)
- [x] RLS: SELECT for anon, no writes for anon
- [x] Seed with at minimum: `enable_goals`, `enable_coupons`, `enable_announcements`, `parser_engine_version`

---

### 2.2 — Supabase: `announcements` Table

- [x] Create `announcements` table:
  ```sql
  CREATE TABLE announcements (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title_ar         TEXT NOT NULL,
    title_en         TEXT NOT NULL,
    body_ar          TEXT,
    body_en          TEXT,
    severity         TEXT NOT NULL CHECK (severity IN ('info','warning','maintenance','force_update')),
    min_app_version  TEXT,
    max_app_version  TEXT,
    action_label_ar  TEXT,
    action_label_en  TEXT,
    action_url       TEXT,
    valid_from       TIMESTAMPTZ NOT NULL DEFAULT now(),
    valid_until      TIMESTAMPTZ,
    is_dismissible   BOOLEAN NOT NULL DEFAULT true,
    priority         INT NOT NULL DEFAULT 0,
    target_countries JSONB NOT NULL DEFAULT '[]',
    is_active        BOOLEAN NOT NULL DEFAULT true,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  ```
- [x] RLS: SELECT for anon, no writes for anon
- [x] Edge Function at `/catalog/announcements`: filters by `is_active = true`, `valid_from <= now()`, `(valid_until IS NULL OR valid_until >= now())`, and `X-App-Version` header against `min_app_version`/`max_app_version`

---

### 2.3 — Drift Schema: `remote_feature_flags` + `remote_announcements`

- [x] Add `remote_feature_flags` Drift table:
  ```
  key              TEXT PK
  value_type       TEXT
  value            TEXT
  rollout_percent  INT
  target_countries TEXT    -- JSON array
  is_active        BOOLEAN
  synced_at        DATETIME
  ```
- [x] Add `remote_announcements` Drift table:
  ```
  id               TEXT PK
  title_ar         TEXT
  title_en         TEXT
  body_ar          TEXT nullable
  body_en          TEXT nullable
  severity         TEXT
  min_app_version  TEXT nullable
  max_app_version  TEXT nullable
  action_label_ar  TEXT nullable
  action_label_en  TEXT nullable
  action_url       TEXT nullable
  valid_from       DATETIME
  valid_until      DATETIME nullable
  is_dismissible   BOOLEAN
  priority         INT
  is_dismissed     BOOLEAN DEFAULT false   -- local user action
  synced_at        DATETIME
  ```
- [x] Write Drift migrations for both
- [x] Add `dismissed_at DATETIME nullable` to `remote_announcements` — set locally when user dismisses

---

### 2.4 — Dart: `FeatureFlagService`

- [x] Create `lib/data/catalog/feature_flag_service.dart`
- [x] Class `FeatureFlagService` injected with `AppDatabase` and `installId` (stable device identifier already in use)
- [x] **Safe defaults registry** — hardcoded `Map<String, dynamic>` at top of file:
  ```dart
  static const _defaults = {
    'enable_goals': true,
    'enable_coupons': false,
    'enable_announcements': true,
    'parser_engine_version': 'v1',
  };
  ```
- [x] Method `bool getBool(String key)`:
  - Read from Drift `remote_feature_flags` by key
  - If not found or `!is_active`: return `_defaults[key] as bool`
  - If `rollout_percent == 100`: return `true`
  - If `rollout_percent == 0`: return `false`
  - Otherwise: compute `sha256("$installId:$key")` → take first 2 bytes as uint16 → `% 100` → return `value < rollout_percent`
  - Result must be **identical** on every call for same installId + key
- [x] Methods: `getString(String key)`, `getInt(String key)`, `getJson(String key)` — same pattern with type-appropriate defaults
- [x] Create Riverpod provider `featureFlagServiceProvider`
- [x] Add sync for flags to `CatalogSyncService.syncAll()`: fetch `/catalog/versions` does not include flags — instead call a separate `/catalog/flags` endpoint that returns all active flags in full (no delta needed, small payload)

---

### 2.5 — Dart: `AnnouncementService`

- [x] Create `lib/data/catalog/announcement_service.dart`
- [x] Method `Future<List<Announcement>> getActiveAnnouncements()`: reads from Drift, filters out dismissed ones, sorted by priority DESC
- [x] Method `Future<void> dismiss(String id)`: sets `is_dismissed = true`, `dismissed_at = now()` in Drift
- [x] Method `bool hasForceUpdate()`: returns true if any active non-dismissed announcement has `severity == 'force_update'`
- [x] Add sync for announcements to `CatalogSyncService.syncAll()`: replace all announcements in Drift with fresh server data (full replace, preserve `is_dismissed` local field)
- [x] Create Riverpod provider `announcementServiceProvider`

---

### 2.6 — UI: Announcement Banner

- [x] Create `lib/features/common/widgets/announcement_banner.dart`
- [x] Shows top-of-screen banner for active non-dismissed announcements with `severity: info | warning | maintenance`
- [x] Displays `title_ar` (app is Arabic-first)
- [x] Has dismiss button if `is_dismissible == true`
- [x] Tapping banner opens `action_url` if set (internal route → `GoRouter.go()`, external URL → `url_launcher`)
- [x] Wire into `app_shell.dart` to show above main content

---

### 2.7 — UI: Force Update Screen

- [x] Create `lib/features/onboarding/force_update_screen.dart`
- [x] Shown when `AnnouncementService.hasForceUpdate() == true`
- [x] Blocks all app navigation (not dismissible)
- [x] Shows announcement body text and action button (links to App Store)
- [x] Check for force update in `app_shell.dart` after each sync cycle — if true, redirect to this screen

---

## Phase 3 — Parser Lab (Admin Validation)

> Goal: No remote parser rule can go live without passing golden tests.

### 3.1 — Supabase: Parser Validation Metadata

- [x] Add columns to `sms_parsers` table:
  ```sql
  ALTER TABLE sms_parsers ADD COLUMN validation_status TEXT DEFAULT 'pending'
    CHECK (validation_status IN ('pending','passed','failed'));
  ALTER TABLE sms_parsers ADD COLUMN golden_test_count INT DEFAULT 0;
  ALTER TABLE sms_parsers ADD COLUMN false_positive_count INT DEFAULT 0;
  ALTER TABLE sms_parsers ADD COLUMN amount_error_count INT DEFAULT 0;
  ALTER TABLE sms_parsers ADD COLUMN validated_at TIMESTAMPTZ;
  ALTER TABLE sms_parsers ADD COLUMN validated_by TEXT;
  ```
- [x] Edge Function `catalog-delta` must NOT return parsers where `validation_status != 'passed'`
- [x] Parsers with `validation_status = 'pending'` or `'failed'` are invisible to the app

---

### 3.2 — Supabase: Golden Test Set Table

- [x] Create `parser_golden_tests` table:
  ```sql
  CREATE TABLE parser_golden_tests (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bank_id          UUID NOT NULL REFERENCES banks(id),
    sender           TEXT NOT NULL,
    message_text     TEXT NOT NULL,
    expected_type    TEXT NOT NULL,      -- 'debit' | 'credit' | 'balance_inquiry' | 'ignored'
    expected_amount  NUMERIC,
    expected_currency TEXT,
    expected_merchant TEXT,
    is_otp           BOOLEAN NOT NULL DEFAULT false,
    is_promo         BOOLEAN NOT NULL DEFAULT false,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  ```
- [x] RLS: SELECT for anon blocked. Only service_role can read/write.

---

### 3.3 — Supabase: Parser Test Edge Function

- [x] Create Edge Function `supabase/functions/parser-test/index.ts`
- [x] Accepts: `{ parser_id: string }` (service_role auth required)
- [x] Loads the parser rule from `sms_parsers`
- [x] Loads all golden tests for `bank_id` from `parser_golden_tests`
- [x] Runs each test through the regex patterns (server-side JS regex, NOT Dart — this is admin-side validation)
- [x] Evaluates pass/fail per test against these strict criteria:
  - `expected_type = 'ignored'` AND parser matches → **critical fail** (false positive)
  - `is_otp = true` AND parser matches → **critical fail** (OTP parsed as transaction)
  - `is_promo = true` AND parser matches → **critical fail** (promo parsed as transaction)
  - Amount extracted differs from `expected_amount` by any value → **amount fail**
  - Any critical fail → overall `validation_status = 'failed'`, stop immediately
  - Any amount fail → `validation_status = 'failed'`
  - All tests pass → `validation_status = 'passed'`
- [x] Updates `sms_parsers` with validation result and counts
- [x] Returns detailed test report JSON

---

### 3.4 — Dart: Isolate-Based Parser Runner

- [x] Create `lib/features/capture/services/parser_isolate.dart` (exists at lib/engine/parser/parser_isolate.dart)
- [x] Function `parseInIsolate(String smsText, String sender, List<ParserRule> rules)` → returns `ParseResult?`
- [x] Spawns a Dart `Isolate`, runs all matching rules, returns result via `ReceivePort`
- [x] Main isolate waits maximum **2 seconds** then kills the worker isolate and returns `null`
- [x] `null` result is treated as unparsed SMS — falls back to manual entry prompt
- [x] `RegExp` objects are compiled fresh inside the isolate (not passed across isolate boundary)
- [x] Update Parser V2 to call `parseInIsolate` instead of running regex inline

---

## Done Checklist Summary

### Phase 0
- [x] 0.1 catalog_metadata Drift table
- [x] 0.2 remote_banks Drift table
- [x] 0.3 remote_parsers Drift table
- [x] 0.4 remote_currencies Drift table
- [x] 0.5 remote_countries Drift table
- [x] 0.6 remote_categories Drift table
- [x] 0.7 Seed JSON files (assets/catalog/)
- [x] 0.8 SeedLoader service

### Phase 1
- [x] 1.1 Supabase sequences + catalog_versions
- [x] 1.2 banks table + trigger + RLS + seed
- [x] 1.3 sms_parsers table + trigger + RLS + seed
- [x] 1.4 currencies table + trigger + RLS + seed
- [x] 1.5 countries table + trigger + RLS + seed
- [x] 1.6 categories table + trigger + RLS + seed
- [x] 1.7 Edge Function: /catalog/versions
- [x] 1.8 Edge Function: /catalog/delta
- [x] 1.9 CatalogSyncService (Dart)
- [x] 1.10 Sync triggers (cold start, resume, pull-to-refresh)
- [x] 1.11 Wire Parser V2 + RulesClient to Drift
- [x] 1.12 Currency + Country Riverpod providers

### Phase 2
- [x] 2.1 Supabase feature_flags table
- [x] 2.2 Supabase announcements table
- [x] 2.3 Drift tables for flags + announcements
- [x] 2.4 FeatureFlagService (SHA-256 rollout)
- [x] 2.5 AnnouncementService
- [x] 2.6 Announcement banner UI
- [x] 2.7 Force update screen UI

### Phase 3
- [x] 3.1 Parser validation metadata columns
- [x] 3.2 Golden test set table
- [x] 3.3 Parser test Edge Function
- [x] 3.4 Dart isolate-based parser runner
