# Phase 4 Plan — AI Cascade, Privacy, Remote Merchant Dictionary, iOS

Status: PLAN ONLY — awaiting approval before any implementation.

---

## 1. AI Cascade (Gemini Flash fallback)

### 1.1 Trigger conditions

The AI layer is layer 6 in the 7-layer pipeline (already stubbed). It fires if and only if:

| Condition | Check |
|-----------|-------|
| No bank profile matched | `parseResult.bankKey == null` |
| Rule confidence below pending threshold | `parseResult.confidence < ParserEngine.pendingThreshold (0.70)` — i.e., rule-based engine returned a result but can't even hold it as pending |
| Categorization fallback | After successful parse, `categoryResult.source == CategorySource.fallback` AND user has unseen merchant → AI merchant categorizer fires separately |

AI is **never called for a message that already has a rule-based result above `pendingThreshold`**, even if that result is pending. The rule system's pending state is intentional — the user reviews it.

"Never per-message" means: AI fires only when the rule system gave up. Not as a pass-through enricher.

### 1.2 What is sent

After `SmsSanitizer.sanitize()` (see §2):
- Sanitized SMS text (amounts kept — they appear in plain bank format; names/numbers stripped)
- Sender ID (bank short code or raw sender string) — not PII
- Detected `TransactionType` if any partial rule matched (as a hint)

What is **never** sent:
- Raw SMS
- Card numbers, account numbers, phone numbers, beneficiary names
- Device install ID, user ID, or any identifier
- Amount (AI must infer it from the sanitized text to enable the grounding check)

### 1.3 Grounding check (mandatory, blocks AI result if fails)

After AI returns a structured result, before saving anything:

```
groundingCheck(aiAmount, sanitizedText):
  candidates = [
    aiAmount.toStringAsFixed(2),
    aiAmount.toStringAsFixed(3),         // KWD/BHD/OMR have 3 decimal places
    Normalizer.normalizeDigits(...)       // Arabic-Indic form
    aiAmount.toString().replace('.', ',') // some Arabic locales use comma
  ]
  return candidates.any((s) => sanitizedText.contains(s))
```

If grounding fails → AI result is **discarded entirely**. The transaction is returned as `ignored` (not even pending) because we have no trustworthy amount. This is intentional: a hallucinated amount is more dangerous than a missed transaction.

### 1.4 Confidence and confirmation

AI-sourced transactions:
- `parseConfidence` capped at **0.79** (same as `genericMaxConfidence`) — never reaches `autoConfirmThreshold` (0.92)
- `source` field set to `TransactionSource.aiParsed` (new enum value)
- Always routed to `pending_confirmation` — user sees the review sheet

AI merchant categorizer:
- Only fires for already-parsed transactions where `categoryResult.source == CategorySource.fallback` and user consent is granted (§2)
- Returns a suggested `categoryKey` at confidence 0.70 — user still confirms
- Stored as `is_user_confirmed = 0` in `merchant_category_map`

### 1.5 API key management — OPEN QUESTION Q1

Three options, need owner decision:

**Option A — dart-define** (simplest): Key passed at build time like Supabase keys. Key lives in the IPA binary, extractable. Acceptable for MVP if rate-limited on the server side.

**Option B — Supabase Edge Function proxy** (recommended): No Gemini key in the binary. App posts sanitized SMS to `ai-parse` Edge Function (authenticated via Supabase anon key). Function calls Gemini and returns structured JSON. Rate limiting enforced server-side per install ID.

**Option C — on-device model** (future): Gemma 2B or Qwen via llama.cpp. No network, no consent needed for privacy. High cold-start latency (~2s), ~400MB download. Deferred to Phase 5.

**→ Decision needed:** A, B, or C?

### 1.6 Files

| Action | File | Change |
|--------|------|--------|
| NEW | `lib/engine/ai/ai_parse_request.dart` | `AiParseRequest` data class (sanitized text, senderHint, typeHint) |
| NEW | `lib/engine/ai/ai_parse_result.dart` | `AiParseResult` data class + static `groundingCheck()` |
| NEW | `lib/engine/ai/gemini_parser_client.dart` | `GeminiParserClient.parse(AiParseRequest, {String apiKey}) → Future<AiParseResult?>` |
| NEW | `lib/engine/ai/ai_merchant_categorizer.dart` | `AiMerchantCategorizer.categorize(String merchant, {String apiKey}) → Future<String?>` (returns category key or null) |
| MODIFY | `lib/engine/parser/parser_engine.dart` | Layer 6: call `GeminiParserClient` when consent granted and confidence < pendingThreshold |
| MODIFY | `lib/engine/categorization/categorizer.dart` | Layer 4 (after fallback): call `AiMerchantCategorizer` when consent granted and source == fallback |
| MODIFY | `lib/engine/models/transaction_source.dart` | Add `aiParsed` enum value |
| MODIFY | `lib/core/backend/rules_client.dart` | Add `aiParsed` case to exhaustive switch |
| MODIFY | `lib/domain/usecases/add_transaction_usecase.dart` | Gate AI call on `_aiConsentGranted` flag; pass sanitized text |
| NEW (Supabase) | `supabase/functions/ai-parse/index.ts` | Edge Function: verify anon JWT → sanitize again server-side → call Gemini API → return JSON |

### 1.7 Open questions

**Q1**: API key strategy (A/B/C above)?

**Q2**: Rate limit. Gemini Flash is cheap but not free. Proposed: 20 AI parse calls/device/day, enforced in Edge Function by install ID hash. Acceptable?

**Q3**: Should AI parse and AI merchant categorization share one opt-in toggle, or be separately gated? (Suggested: one toggle — "AI suggestions" — covering both.)

**Q4**: What happens if the AI parse grounding check fails repeatedly for the same sender? Should we track failure counts and suppress AI for that sender after N failures?

---

## 2. Privacy / Sanitization Pipeline

### 2.1 Consent flow

- **First trigger**: when a message would go to AI (condition in §1.1 met), the AI path is held and a consent sheet is shown instead.
- **Settings**: "AI suggestions" toggle in the settings screen; defaults to OFF.
- **Consent is stored** in `user_settings.ai_consent_granted INTEGER NOT NULL DEFAULT 0` (new column, added via `_ensureColumn` in `_runCompatibilityMigrations`).
- Consent can be revoked at any time from settings. Revocation is immediate — no pending AI calls.
- Consent is **per-device, not per-account**. Supabase account status does not affect it.

### 2.2 What SmsSanitizer strips

New file `lib/engine/privacy/sms_sanitizer.dart`. Applied before any data leaves the device.

| PII type | Pattern | Replacement |
|----------|---------|-------------|
| 16-digit card numbers | `\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}` | `[CARD]` |
| Last-4 only form `*1234` | `\*\d{4}` | kept — not sensitive (already masked) |
| Account numbers (10–20 digits) | `\b\d{10,20}\b` (after excluding amounts — must not match `1,234.56`) | `[ACCOUNT]` |
| Saudi phone `05XXXXXXXX` | `\b05\d{8}\b` | `[PHONE]` |
| International phone | `\+\d{7,15}\b` | `[PHONE]` |
| Beneficiary name after `إلى:` / `To:` | `(إلى|الى|To)\s*:?\s*.+` → capture preposition + redact remainder | `إلى [REDACTED]` |
| Arabic greeting + name `عزيزي NAME` | `(عزيزي|العميل|عميلنا)\s+\S+` | `[REDACTED]` |

What is **not stripped** (intentionally):
- Amounts (AI needs them for the grounding check to pass)
- Merchant names (AI needs them for categorization)
- Bank short codes / sender IDs (routing information)
- Dates and times (not PII)

### 2.3 Sanitizer must not break parser

`SmsSanitizer` runs **only** on the copy sent to AI. The raw SMS is always stored locally as `raw_message` in Drift and used by the rule-based parser. The parser never receives a sanitized string.

### 2.4 Files

| Action | File | Change |
|--------|------|--------|
| NEW | `lib/engine/privacy/sms_sanitizer.dart` | Regex-based PII stripping; pure function, no DB |
| MODIFY | `lib/data/db/app_database.dart` | Add `ai_consent_granted INTEGER NOT NULL DEFAULT 0` to `user_settings` via `_ensureColumn` (no version bump needed — `_ensureColumn` is idempotent) |
| NEW | `lib/features/settings/widgets/ai_consent_sheet.dart` | Bottom sheet: what is sent, what is not, toggle |
| MODIFY | `lib/features/settings/settings_screen.dart` | Add "AI suggestions" row that opens `AiConsentSheet` |
| MODIFY | `lib/l10n/app_en.arb` + `app_ar.arb` | Add consent copy strings |
| NEW | `test/engine/sms_sanitizer_test.dart` | Golden tests: card number stripped, phone stripped, greeting name stripped, amounts kept, merchant kept |

### 2.5 Open questions

**Q5**: Server-side re-sanitization. The Edge Function (if Option B is chosen for Q1) should apply the same sanitizer rules before forwarding to Gemini, in case a client bug leaks PII. Should this be explicitly planned or treated as a server-side implementation detail?

**Q6**: Beneficiary name stripping: `إلى:NAME` is the beneficiary. The dedup hash currently includes `merchantNormalized` which comes from `rawMerchant`. For transfers, `rawMerchant` could be the beneficiary name. Should `SmsSanitizer` also strip the portion that populates `rawMerchant` for transfer-type transactions, or only for AI-bound text?

---

## 3. Remote Merchant Dictionary Migration

### 3.1 Current state

`CategorySeeds.keywordRules` is a hardcoded `Map<String, String>` in `category_seeds.dart` (70+ entries after Phase 3). Two callers:
- `lib/data/db/database_seed.dart` — seeds `merchants` + `merchant_category_map` tables on first install
- `lib/engine/categorization/categorizer.dart` — step 3 of the 4-step classification chain

The `remote_categories` table already exists and syncs from Supabase, but it holds **category definitions** (icon, color, sort order), not merchant-keyword mappings.

### 3.2 Target architecture

Add a new `remote_merchant_keywords` table:

```sql
CREATE TABLE IF NOT EXISTS remote_merchant_keywords(
  id TEXT PRIMARY KEY,
  keyword TEXT NOT NULL,          -- matched with .contains(), case-insensitive
  category_key TEXT NOT NULL,     -- stable string like 'restaurants'
  language TEXT NOT NULL,         -- 'ar', 'en', or 'any'
  country_code TEXT NOT NULL,     -- 'SA', 'EG', 'KW', 'AE', or 'ALL'
  priority INTEGER NOT NULL,      -- higher = checked first; default 0
  is_active INTEGER NOT NULL,
  is_deleted INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rmk_country ON remote_merchant_keywords(country_code, is_active);
```

**Sync**: piggybacked onto existing `catalog-delta` Edge Function under a new `merchant_keywords` category key, same delta-sync protocol as banks/parsers/currencies. Schema version bump to **6**.

**Categorizer resolution order** (updated):
1. User-confirmed map (`merchant_category_map`, `is_user_confirmed = 1`) — unchanged, highest priority
2. Remote merchant keywords (`remote_merchant_keywords`, sorted by priority DESC)
3. Local fallback seeds (`CategorySeeds.keywordRules`) — unchanged, never removed
4. Type rules (withdrawal → cash, income → income, etc.) — unchanged
5. AI merchant categorizer (§1) — only with consent and only for fallback

`CategorySeeds.keywordRules` remains. It is never deleted. It is the offline safety net when the device has not yet synced the remote catalog.

### 3.3 Anonymized unknown-merchant feedback loop

When the categorizer reaches step 5 (AI or final fallback) AND `rawMerchant != null`:

1. Normalize the merchant string with `TransactionDedup.normalizeMerchant(rawMerchant)`.
2. INSERT into `pending_merchant_feedback(normalized_keyword TEXT, seen_count INTEGER, last_seen_at TEXT)` (upsert on conflict — increment `seen_count`).
3. On each catalog sync (existing `CatalogSyncService.sync()` call), if `pending_merchant_feedback` has ≥ 5 distinct entries, POST to new Edge Function `merchant-feedback`:

```json
{ "keywords": ["TALABAT EGYPT", "FAWRY BABI", "BM ONLINE"] }
```

Never sent: amounts, dates, user ID, transaction ID, install ID, device info.

4. After successful POST, truncate `pending_merchant_feedback`.
5. Admin reviews in admin panel → adds approved keywords to `merchant_keywords` Supabase table → next sync delivers them to all devices.

### 3.4 Files

| Action | File | Change |
|--------|------|--------|
| MODIFY | `lib/data/db/app_database.dart` | Add `remote_merchant_keywords` table, `pending_merchant_feedback` table, bump schema to **6**, add `if (version < 6)` migration block |
| MODIFY | `lib/data/catalog/catalog_daos.dart` | Add `RemoteMerchantKeywordsDao` class (upsert, getActive, getByCountry) |
| MODIFY | `lib/data/catalog/catalog_sync_service.dart` | Handle `merchant_keywords` delta category in the sync switch |
| NEW | `lib/data/catalog/merchant_feedback_client.dart` | `postAnonymizedFeedback(List<String> keywords)` → POST to `merchant-feedback` Edge Function; strips any remaining PII from keywords before sending |
| MODIFY | `lib/engine/categorization/categorizer.dart` | Add remote keyword step (step 2 above) before local seeds; accept `List<RemoteMerchantKeyword>? remoteKeywords` constructor parameter |
| MODIFY | `lib/core/di/app_providers.dart` | Pass `RemoteMerchantKeywordsDao` to `Categorizer` via `addTransactionUseCaseProvider` |
| MODIFY | `supabase/migrations/` | New file `0006_merchant_keywords.sql` — `merchant_keywords` table + RLS + `catalog_versions` entry |
| NEW (Supabase) | `supabase/functions/merchant-feedback/index.ts` | Accept POST of keyword list; INSERT into `merchant_keywords_pending` for admin review; verify anon JWT; rate-limit by install ID hash |
| MODIFY (admin) | `../admin/app/parsers/` → new route `../admin/app/merchants/` | Admin panel page to review and approve pending merchant keywords |

### 3.5 Open questions

**Q7**: Should `remote_merchant_keywords` support regex patterns or only substring matching? Currently the hardcoded seeds all use substring (`.contains()`). Regex would be more powerful but harder to author in the admin panel.

**Q8**: The existing `database_seed.dart` calls `CategorySeeds.keywordRules` to pre-populate `merchants` + `merchant_category_map` on first install. After remote migration, should this seed step be kept, removed, or made conditional on whether `remote_merchant_keywords` is empty?

**Q9**: Country-code filtering. The device knows the user's country from `user_settings.country`. Should the categorizer filter remote keywords to `country_code IN (user_country, 'ALL')` or apply all keywords globally? (Gulf country users would get EG keywords applied which are mostly harmless but noisy.)

---

## 4. iOS Strategy

### 4.1 Current state (already built — more complete than expected)

Reading the codebase reveals the iOS capture path is **fully implemented** at the native level:

| Component | File | Status |
|-----------|------|--------|
| App Intent | `ios/BankMessageShortcuts/BankMessageShortcuts.swift` | ✅ Complete — `PostBankStatusIntent` exposes "Post Bank Status" to Shortcuts |
| Share Extension | `ios/ShareBankMessage/ShareViewController.swift` | ✅ Exists |
| Shared queue | `ios/Runner/SharedCaptureStore.swift` (+ copies in each target) | ✅ FIFO queue via App Group UserDefaults |
| App Group | `ios/Runner/Runner.entitlements` | ✅ `group.com.youssefsafwat.mali` |
| Flutter drain | `lib/features/capture/services/native_capture_bridge.dart` | ✅ `consumePendingSharedMessages()` wired to `SharedCaptureStore.consumePendingPayloadsJSON()` |
| Onboarding | `lib/features/onboarding/ios_shortcut_screen.dart` | ✅ 8-step guide with bilingual copy |
| Setup docs | `ios/SHORTCUT_SETUP.md` | ✅ Exists |

The App Group entitlement is present in `Runner.entitlements`. The `pbxproj` changes in the working tree likely add `BankMessageShortcuts` and `ShareBankMessage` extension targets to the Xcode project.

### 4.2 What is actually missing (remaining gaps)

**Gap 1 — Background drain timing.** The Flutter side drains via `consumePendingSharedMessages()` which is called by `NativeCaptureBridge`. But when exactly is it called? From reading `captured_message_processor.dart` and the app startup, the drain likely only happens when the app is foregrounded. A message enqueued at 10am when the app is killed stays unprocessed until the user opens Mali.

Proposed: wire the drain call into `applicationDidBecomeActive` (already available in `AppDelegate.swift`) so it fires on every foreground. On the Dart side, call it from the `AppShell` `initState` or a background isolate wakeup.

**Gap 2 — Sender detection from Shortcuts.** The `PostBankStatusIntent` accepts an optional `sender` parameter. The Shortcuts automation step "Message Contents" filter does NOT include the sender name — it only provides the message body. Without a sender, the parser falls back to generic heuristics.

Proposed: add a second optional Shortcuts step (or use the `message.sender` Shortcuts variable if iOS exposes it) to pass the sender. This needs investigation — iOS Shortcut variables for SMS sender may not be available for Messages automation.

**Gap 3 — Re-entry after notification tap.** When the app sends a review notification (pending transaction) and the user taps it, the app opens via `CaptureRuntime.requestConfirmation(transactionId)`. This path works on Android (which reads the intent). On iOS, the `UNNotificationResponse` handler needs to be wired to call `CaptureRuntime.requestConfirmation`. This likely exists but should be verified.

**Gap 4 — `openAppWhenRun: true` vs silent.** `PostBankStatusIntent` currently has `openAppWhenRun: true`, which opens Mali every time an SMS arrives. For banks that send 5-10 SMS per day this is disruptive. The `IosShortcutScreen` instructs users to disable "Show When Run" but `openAppWhenRun` is hardcoded to true. Either make it configurable per-Shortcut or set it to `false` and rely on the notification instead.

### 4.3 Files needed (iOS workstream)

| Action | File | Change |
|--------|------|--------|
| VERIFY | `ios/Runner/AppDelegate.swift` | Confirm `applicationDidBecomeActive` triggers a drain call to Flutter |
| MODIFY | `lib/features/app/app_shell.dart` (or equivalent) | Call `NativeCaptureBridge.consumePendingSharedMessages()` on `initState` and app resume |
| MODIFY | `ios/BankMessageShortcuts/BankMessageShortcuts.swift` | Change `openAppWhenRun: Bool = true` to `false` (or remove so users can choose) |
| INVESTIGATE | iOS Shortcuts `Message` trigger variables | Can `message.sender` be passed as the `sender` parameter? Requires manual testing on device. |
| VERIFY | `lib/features/capture/services/android_sms_capture_service.dart` | Confirm notification tap → `CaptureRuntime.requestConfirmation` path works on iOS |
| MODIFY (if needed) | `ios/Runner/AppDelegate.swift` | Wire `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:)` to call Flutter for notification tap deep link |

### 4.4 This is a separate workstream

The native iOS side is already more complete than the Android side in some respects. The remaining gaps (drain timing, sender detection, notification tap deep link) are **testing and integration** work, not architecture work. They cannot be fully validated without a real device (sideload or signed build) or a hardware simulator with SMS capability.

**Recommended**: treat iOS as a parallel track that does not block Phases 4A (AI) or 4B (privacy). Gate iOS ship on a manual QA pass with a physical device.

---

## Summary: open questions requiring owner decisions before implementation

| # | Question | Blocks |
|---|----------|--------|
| Q1 | AI API key strategy: dart-define / Edge Function proxy / on-device? | §1 (AI cascade) |
| Q2 | Rate limit: 20 AI calls/device/day via Edge Function? | §1 (AI cascade) |
| Q3 | One AI toggle covering both parse + categorization, or separate? | §1, §2 |
| Q4 | Suppress AI for a sender after N consecutive grounding failures? | §1 |
| Q5 | Server-side re-sanitization in Edge Function: plan it or implicit? | §2 |
| Q6 | Strip beneficiary names from dedup hash input (transfer transactions)? | §2 |
| Q7 | Remote merchant keywords: substring only, or also regex? | §3 |
| Q8 | Keep `database_seed.dart` keyword seeding after remote migration? | §3 |
| Q9 | Country-code filter on remote keywords: user country + ALL, or global? | §3 |

## Implementation order (proposed, contingent on Q1 answer)

1. **4A** — Privacy/sanitization + consent (§2) — prerequisite for everything else; no external dependency
2. **4B** — Remote merchant dictionary (§3) — independent of AI; delivers value immediately
3. **4C** — AI cascade (§1) — requires 4A (sanitizer), Q1 resolved, Edge Function deployed
4. **iOS gaps** — parallel track; does not block 4A–4C

Each sub-phase gets its own review gate before the next begins.
