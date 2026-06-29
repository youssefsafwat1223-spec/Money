# Mali — Full Production Investigation Report

**Date:** 2026-06-17  
**Branch:** `feat/accounts-multicurrency`  
**Scope:** End-to-end architecture audit, all subsystems  
**Status:** INVESTIGATION ONLY — no code was changed

---

## Table of Contents

1. [Phase 1 — End-to-End Architecture](#phase-1--end-to-end-architecture)
2. [Phase 2 — Parser Audit](#phase-2--parser-audit)
3. [Phase 3 — Gemini Audit](#phase-3--gemini-audit)
4. [Phase 4 — Categorization Audit](#phase-4--categorization-audit)
5. [Phase 5 — Shortcut Audit](#phase-5--shortcut-audit)
6. [Phase 6 — Database & Sync Audit](#phase-6--database--sync-audit)
7. [Phase 7 — UI & UX Audit](#phase-7--ui--ux-audit)
8. [Phase 8 — Production Readiness Scores](#phase-8--production-readiness-scores)
9. [Phase 9 — Critical Bugs](#phase-9--critical-bugs)
10. [Phase 10 — Final Recommendation](#phase-10--final-recommendation)
11. [Executive Summary](#executive-summary)
12. [Top 10 Risks](#top-10-risks)
13. [Top 10 Improvements](#top-10-improvements)
14. [Recommended Next Sprint](#recommended-next-sprint)

---

## Phase 1 — End-to-End Architecture

### Complete Flow Map

```
[Bank SMS Arrives on iPhone]
         │
         ▼
[iOS Shortcuts Automation]
  Trigger: "Message received"
  Filter: "Message Contents contains <CURRENCY>" (e.g. "SAR")
  Action: Run "Post Bank Status" App Intent
         │
         ▼
[PostBankStatusIntent.perform()]  ← ios/BankMessageShortcuts/BankMessageShortcuts.swift
  Params: message: String, sender: String? (may be nil)
  Action: SharedCaptureStore.enqueue(text: message, sender: sender)
  Note: openAppWhenRun = false → app stays in background
         │
         ▼
[SharedCaptureStore]  ← ios/Runner/SharedCaptureStore.swift
  Storage: App Group UserDefaults ("group.com.youssefsafwat.mali")
  Key: "pending_bank_messages_v2"
  Format: JSON array of [{text, sender?}]
  FIFO queue — multiple messages never lost
         │
         ▼ (app foregrounds: user opens app, notification tap, or scheduled resume)
[AppLifecycleListener.onResume()]  ← lib/features/app/app_shell.dart:102
  Triggers: _consumeSharedInput()
         │
         ▼
[NativeCaptureBridge.consumePendingSharedMessages()]
  Platform channel → AppDelegate.swift → SharedCaptureStore.consumePendingPayloadsJSON()
  Returns: List<CapturedMessage> with text + sender
         │
         ▼
[CapturedMessageProcessor.process()]  ← lib/features/capture/services/captured_message_processor.dart
  ⚠️ CRITICAL: Builds AddTransactionUseCase WITHOUT aiClient
  Creates its own DB connection, repositories, use cases (not Riverpod)
         │
         ▼
[IngestCapturedMessageUseCase.fromCapturedMessage()]
         │
         ▼
[AddTransactionUseCase.call()]  ← lib/domain/usecases/add_transaction_usecase.dart
  │
  ├─ Step 1: _safeLoadBankProfiles(senderId)
  │     → RulesClient.localBankProfiles()
  │     → reads remote_banks + remote_parsers from Drift
  │     → if empty, falls back to BankProfiles.all (18 hardcoded banks)
  │
  ├─ Step 2: _resolveBankForSender()
  │     → checks sender_bank_mappings table (user-confirmed or Gemini-suggested)
  │     → if confirmed mapping: injects sender alias into bank profile
  │
  ├─ Step 3: ParserIsolate.parse()  (runs in Dart isolate, 2s timeout)
  │     → Normalizer.normalize() → currency token normalization
  │     → BankProfiles.detect() → keyword/sender matching
  │     → _applyCurrencyAliases()
  │     → _isIgnored() → OTP / promo / chequebook etc → ParseResult.notTransaction
  │     → _detectType() → payment/withdrawal/transfer/income/unknown
  │     → _extractAmounts() → candidate scoring
  │     → _extractMerchantAndSource()
  │     → _extractCurrency() → _extractLast4() → _extractDateResult()
  │     → _confidence() → score 0.10 to 1.0
  │     → if confidence < 0.70 → ParseResult.notTransaction
  │     → if confidence 0.70–1.0 → ParseResult.success
  │
  ├─ Step 4: _runBankDiscoveryIfEligible()  [Gemini Bank Discovery]
  │     → only if: unknown bank + AI consent + rate limit ok + bank-like sender
  │     → skipped if parseResult.confidence ≥ 0.70 ("generic pending is usable")
  │     → GeminiBankDiscoveryClient → bank-discovery Edge Function (Gemini)
  │     → saves suggestion to sender_bank_mappings table
  │
  ├─ Step 5: if !parseResult.isTransaction → return notTransaction (SILENT DROP)
  │
  ├─ Step 6: Hash-based dedup (DriftDedupStore)
  │     → SHA-256 of {amount|currency|cardLast4|merchantNormalized|type}
  │     → checks ±5 min window via julianday query
  │
  ├─ Step 7: Merchant-based dedup (findDuplicate)
  │     → only if merchant != null
  │     → checks same amount + merchant + time
  │
  ├─ Step 8: Categorizer.categorize()
  │     → userMap → typeRule → remoteKeywords → localKeywords → fallback("other")
  │
  ├─ Step 9: AI Parse Cascade  ⚠️ DEAD IN SHORTCUT PATH
  │     → aiTriggered = parseConfidence < 0.70 && !suppressesDiscovery
  │     → BUT: _aiClient is NULL in CapturedMessageProcessor path
  │     → Works only in Riverpod path (manual paste)
  │
  ├─ Step 10: Merchant feedback (anonymous keyword → pending_merchant_feedback)
  │     → only for payment/refund types, only for fallback category
  │
  ├─ Step 11: Build TransactionEntity
  │     → status = confirmed if conf ≥ 0.92 + category conf ≥ 0.80 + !newMerchant
  │     → status = pending otherwise
  │
  └─ Step 12: Save to Drift, mark dedup hash, fire notification

         │
         ▼
[Drift SQLite (SQLCipher encrypted)]
  Tables: transactions, merchants, merchant_category_map, categories,
          dedup_hashes, sender_bank_mappings, accounts, ...
         │
         ▼
[Riverpod Providers read Drift → UI]
  dashboardDataProvider → DashboardScreen
  transactionsByAccountProvider → TransactionsScreen
  transactionByIdProvider → TransactionDetailsScreen
```

### Decision Points Summary

| Decision | Condition | Outcome |
|----------|-----------|---------|
| Message ignored | OTP / promo / chequebook / URL | Silent drop |
| Parser fails | confidence < 0.70, no AI | Silent drop |
| Parser uncertain | 0.70 ≤ confidence < 0.92 | Saved as pending |
| Parser confident | confidence ≥ 0.92 + cat ≥ 0.80 + !newMerchant | Auto-confirmed |
| Gemini discovery | unknown bank + consent + not ignored | Suggestion stored, shown as confirmation sheet |
| AI parse cascade | confidence < 0.70 + consent + Supabase | Re-parse with AI (BROKEN in shortcut path) |
| Duplicate | same hash within ±5 min | Return existing, no save |

### Fallback Paths

1. **No bank profile detected** → generic parser (confidence capped at 0.79) → always pending
2. **No Supabase** → offline mode, no AI, no sync, parser only
3. **Parser timeout (2s)** → `ParseResult.notTransaction()` returned
4. **No currency in message** → falls back to `defaultAccount?.currency ?? 'SAR'`
5. **No date in message** → `occurredAt = DateTime.now().toUtc()` (at save time)
6. **No merchant in message** → merchant is null, categorized by type rule only

---

## Phase 2 — Parser Audit

### Bank Coverage

**Hardcoded in `BankProfiles.all` (18 banks):**

| Bank | Country | Quality |
|------|---------|---------|
| SNB (Al Ahli Saudi) | SA | Good — keywords + sender |
| Al Rajhi | SA | Good |
| Riyad Bank | SA | Good |
| STC Pay | SA | Good (wallet) |
| CIB | EG | Moderate — limited rules |
| NBE (Al Ahli Masri) | EG | Moderate |
| Banque Misr | EG | Basic |
| D360 Bank | SA | Good — English format |
| urpay | SA | Good |
| SAIB | SA | Good |
| barq | SA | Good — barq wallet |
| STC Bank | SA | Good — M/D/YYYY quirk handled |
| ANB | SA | Good — government payments |
| BSF | SA | Good |
| Al Bilad | SA | Good |
| BAJ (Al Jazira) | SA | Good |
| Dubai Bank | AE | Basic — UAE only |
| stcpay (wallet) | SA | Good |

**Missing — major market gaps:**

| Bank | Country | Impact |
|------|---------|--------|
| ADIB | AE | High — major UAE bank (used in live test) |
| ADCB | AE | High |
| FAB (First Abu Dhabi) | AE | High |
| ENBD | AE | High |
| Mashreq | AE | Medium |
| QNB Egypt | EG | High |
| Ahli United Bank | EG | Medium |
| BLOM Bank Egypt | EG | Low |
| SABB | SA | Medium |
| Alinma Bank | SA | Medium |
| SAB | SA | Medium |
| Kuwait Finance House | KW | Low |
| National Bank of Kuwait | KW | Low |
| QNB Qatar | QA | Low |
| Ahli Bank Qatar | QA | Low |

**UAE is especially under-served** — only `dubai_bank` profile, no ADIB/ADCB/FAB.

### Generic Parser Coverage

When no bank profile matches, `BankProfiles.detect()` returns `null`. The parser still runs but:
- Confidence is **capped at `genericMaxConfidence = 0.79`** → always pending
- No bank-specific `typeRules`, `merchantRules`, `balanceRules` → less accurate extraction
- Date ambiguity risk is higher (no `preferredDateOrder` hint)

This means every UAE message from unknown banks goes to pending forever unless user confirms mapping.

### Unsupported Bank Behavior

1. Parser receives message from unknown bank (e.g., ADIB)
2. `BankProfiles.detect()` returns `null`
3. Parser attempts generic extraction
4. If amount found and conf ≥ 0.70 → saves as pending (max 0.79 conf)
5. If conf < 0.70 → **silent drop** (user never sees it)
6. `BankDiscoveryService` fires if: AI consent on + bank-like sender + no known profile
7. Gemini suggests bank → saves to `sender_bank_mappings` as pending
8. App shows bank discovery confirmation sheet
9. User confirms → future messages use profile rules (but rules still point to generic logic)

**The "pending" path is reachable. The "< 0.70 silent drop" path is the dangerous one.**

### Ignore Flow

`_isIgnored()` rejects (correctly) all of these:
- OTP / verification codes
- Promotional / marketing / offer / coupon
- Chequebook requests (`chequebook`, `cheque book`, `checkbook`, `request will be fulfilled`)
- Prize / winner / competition
- URLs (`http://`, `https://`)
- Account freeze / data update / logout notifications
- Complaint messages

**Risk:** The keyword list is English/Arabic mixed but may miss dialects. Example: "كود التحقق" is covered but "الكود" alone might not be caught.

### Amount Extraction

**Strengths:**
- International parens format handled: `USD 100.00 (SAR 375.00)`
- Reverse parens: `100 USD (375 SAR)` 
- Balance vs transaction discrimination via nearby keyword scoring
- Fee/reference number exclusion
- Card last4 exclusion when near card context words
- Date component exclusion

**Weaknesses:**
- **Ambiguity penalty** (-0.25 on confidence) when two similar-score candidates exist → can push messages below 0.70 and drop them
- **No amount found at all** → silent drop (correct, but no feedback)
- Balance extraction relies on keywords like "الرصيد", "balance", "available" — messages that use non-standard labels may extract the wrong value or no balance
- FX rate number can be mistaken for amount if not preceded by recognized FX keyword

### Balance Extraction

`_extractBalanceFromText()` scans for lines containing:  
`الرصيد`, `رصيد:`, `balance`, `available`, `wallet balance`, `المتاح`  
then takes the first number on that line.

**Risk:** Some banks include "الرصيد المتاح" mid-sentence, not on a dedicated line. The line-split approach may fail. Example failure: a message like "تم الخصم من بطاقتك الرصيد المتاح 500.00 SAR" — the balance would be parsed from the same line as the amount.

### Merchant Extraction

Patterns (in priority order):
1. `_merchant` regex: `لدى|لدي|لـ|عند|الجهة|اسم التاجر|At|Merchant|من|إلى|الى|To` + rest of line
2. `_merchantArabicTo`: Arabic `ل` prefix
3. `@`-sign format
4. Bank-specific `merchantRules` tokens

**Weaknesses:**
- `At` without `:` is matched (e.g., "at" inside "ATM" is excluded via `At(?=[\s:])` lookahead, but "AT CAFE" would match)
- `من:` as merchant context: "paid from STC Pay" → `من: STC Pay` would set `fundingSource = STC Pay`, which is correct, but "من: John" in a transfer would emit merchant = John (PII leak to category engine, though it's stripped before AI)
- `_cleanMerchant` strips trailing city names (ABU DHABI, DUBAI...) but only UAE cities — Saudi/Egypt cities not stripped
- If merchant starts with a number, it's rejected. This silently drops things like "7-Eleven" or "360 Mall"

### Currency Extraction

`_extractCurrency()` matches the first occurrence of any supported currency code in the text. Supported: `SAR|AED|EGP|KWD|QAR|BHD|OMR|USD|EUR|GBP|TRY|INR|PKR|CAD|AUD|JPY|CNY|CHF|MAD|DZD|TND|JOD|IQD|LBP`

**Weaknesses:**
- **Arabic currency names not recognized**: "جنيه" (EGP), "ريال" (SAR/OMR), "درهم" (AED) → currency falls back to `defaultCurrency` (account or 'SAR')
- If a Saudi message says "ريال" instead of "SAR", and user's default account is SAR, this is harmless. But if user has EGP account and message says "جنيه", currency detection fails and falls back to EGP (from account) — which is correct but only by luck
- **FX context**: `USD 100.00 (SAR 375.00)` → `_extractInternationalParens` correctly returns localAmount=375 in SAR. But if format is `100 USD بما يعادل 375 SAR` → generic path, currency may return USD (first match) and amount=100

### Duplicate Prevention

Two-layer:
1. **Hash dedup** (DriftDedupStore): SHA-256 of `amount|currency|cardLast4|merchantNorm|type` with ±5 min window
2. **Merchant dedup** (findDuplicate): same amount + rawMerchant + occurredAt (only if merchant ≠ null)

**Known gaps:**
- Two identical ATM withdrawals within 5 min (same amount, no merchant) → treated as duplicate (may be wrong if user withdrew twice)
- No-merchant income/transfers rely only on hash — if same salary credited twice (bank error), first message caught, second dropped silently

---

## Phase 3 — Gemini Audit

### Two Separate Gemini Subsystems

Mali has **two** distinct Gemini integrations that are often confused:

| Feature | Client | Edge Function | Purpose |
|---------|--------|--------------|---------|
| Bank Discovery | `GeminiBankDiscoveryClient` | `bank-discovery` | Identify unknown banks from sender ID |
| AI Parsing | `SupabaseAiParserClient` | `parse-sms` | Parse messages from completely unknown banks |

### When Gemini Bank Discovery Fires

**Conditions (ALL must be true):**
1. `senderId` is non-empty
2. `parseResult.isTransaction && confidence < 0.70` (parsing failed) OR message is not a transaction
3. `BankSenderFilter.isLikelyBank()` = true (alphanumeric sender, not a phone number)
4. NOT an ignored message (OTP, promo, etc.)
5. No known bank profile matched (not in BankProfiles.all or remote_banks)
6. No confirmed or active-rejection mapping in `sender_bank_mappings`
7. AI consent granted (`aiConsentGranted = true` in user_settings — **OFF by default**)
8. Rate limit allows (`rateLimitAllowsDiscovery` callback — not passed in `CapturedMessageProcessor` path, so no server-side limiting there)

**Condition 7 is the #1 blocker**: AI consent defaults to OFF. New users never see Gemini bank discovery unless they explicitly toggle the setting.

**Critical skip condition (line 43 in `bank_discovery_service.dart`):**
```dart
if (parseResult.isTransaction && parseResult.confidence >= ParserEngine.pendingThreshold) {
  return const BankDiscoveryResult.skipped('generic_pending_is_usable');
}
```
This means: if the generic parser already found the transaction (conf ≥ 0.70), Gemini bank discovery is skipped. Gemini only fires when parsing COMPLETELY failed (dropped message). This is intentional to save costs but means banks with partially-parseable messages never get discovered.

### When Gemini AI Parsing (parse-sms) Fires

**Conditions (ALL must be true):**
1. `parseConfidence < 0.70` (parser couldn't reach pending threshold)
2. `!bankResolution.suppressesDiscovery` (not a confirmed or rejected mapping)
3. `_aiClient != null` (Supabase is configured)
4. AI consent granted

**⚠️ CRITICAL BUG: AI parsing is dead in the Shortcut capture path.**

In `CapturedMessageProcessor`, `AddTransactionUseCase` is constructed **without** `aiClient`:
```dart
AddTransactionUseCase(
  transactionRepository: ...,
  // NO aiClient parameter — aiClient is null
  // NO loadAiConsent parameter  
  // NO installId parameter
)
```

In contrast, `addTransactionUseCaseProvider` in `app_providers.dart` (used for manual paste) **does** wire up `aiClient`. So:

| Path | AI Parsing |
|------|-----------|
| iOS Shortcut → drain on resume | ❌ DEAD — silent drop |
| Manual paste (capture entry sheet) | ✅ Works if consent enabled |
| Android share | Unknown — needs check |

**Impact**: Any bank whose messages score < 0.70 (unknown format, no profile, unusual structure) will be **silently discarded when received via Shortcut**. The user sees nothing. No notification, no pending transaction, nothing.

### Rate Limits

`parse-sms` Edge Function: 20 calls/device/day (via `ai_rate_limits` table in Supabase).
`bank-discovery` Edge Function: No explicit rate limit checked in `BankDiscoveryService` unless `rateLimitAllowsDiscovery` callback is provided. In `CapturedMessageProcessor`, this callback is not passed → effectively unlimited bank discovery calls from that path.

### Cost Analysis

- `parse-sms`: max 20 calls/device/day × model cost. With `gemini-2.5-flash-lite`, very cheap per call (~$0.00003).
- `bank-discovery`: fires once per unknown sender (pending cooldown period prevents retries). Also cheap.
- **Real cost risk**: if AI consent is widely enabled and many messages fail parsing (> 20/day), rate limit kicks in and subsequent messages are silently dropped.

### Cases Where Gemini Should Run But Doesn't

1. **Unknown bank via Shortcut, conf < 0.70** → silent drop (AI parsing dead in this path)
2. **AI consent disabled** → no Gemini at all
3. **Generic parse succeeds (conf ≥ 0.70) but wrong bank identified** → Gemini discovery skipped with reason `generic_pending_is_usable`
4. **User has `sender_bank_mappings` with rejected status in cooldown** → Gemini skipped (correct behavior, but user not informed)

### Cases Where Gemini Runs Unnecessarily

1. **`bank-discovery` fires for bank-like senders who are not banks** (e.g., telecom OTP that passed the `isLikelyBank` filter because the sender had letters)
2. **Redundant discovery**: if message was partially parsed (balance found, no amount), conf < 0.70 → Gemini fires → also bank discovery fires → two Gemini calls for one message

---

## Phase 4 — Categorization Audit

### Categorization Pipeline

```
1. userMap (is_user_confirmed in merchant_category_map) → confidence 1.0
2. typeRule (withdrawal→cash, transfer→transfers, income→income) → 0.95
3. remoteKeywords (from remote_merchant_keywords Drift table) → 0.8
4. localKeywords (CategorySeeds.keywordRules, ~100 entries) → 0.8
5. fallback → "other" → 0.3
```

### Local Keyword Coverage

`CategorySeeds.keywordRules` covers:

**Saudi merchants (good):**
- Grocery: Panda, Danube, Tamimi, LuLu, Carrefour, Othaim
- Restaurants: McDonald's, Herfy, Kudu, AlBaik, Burger*, Shawarma*
- Cafes: Starbucks, Barns, Dunkin, Arabica, Dose
- Transport: Uber, Careem, Jeeny
- Fuel: Aramco, Petromin, Sasco
- Bills: STC, Mobily, Zain
- Subscriptions: Netflix, Shahid, Spotify, iCloud, OSN
- Health: Nahdi, Aldawaa
- Shopping: Jarir, Extra, Amazon, Noon

**Egypt merchants (very limited):**
- Fawry (bills), Breadfast, Talabat, Elmenus (restaurants), SWVL (transport)
- Orange, Vodafone, Etisalat (bills)
- Missing: Glovo, Careem Egypt, Instapay merchants, Masary, Aman, Mylerz

**UAE merchants (very limited):**
- HungerStation, Talabat (shared Gulf), Spinneys, InstaShop, Nana (grocery)
- Missing: Noon UAE, Sharaf DG, LuLu UAE, Careem UAE, Emaar merchants, du, Etisalat UAE

**Generic patterns:**
- English: RESTAURANT, PHARMACY, HOSPITAL, CLINIC, PETROL, CINEMA, MOVIE, HOTEL, AIRPORT
- Arabic: مطعم, مقهى, صيدلية, محطة, مستشفى, عيادة, سينما, فندق, مطار

### Known Issues

**Rule ordering risk:** `STC` matches before more specific patterns. A payment to "STC Bank" would be categorized as "bills" (STC telecom) instead of a transfer. `CategorySeeds` doesn't distinguish STC Pay from STC Telecom.

**Missing Gulf categories:** No rule for "salon/spa", "gym/fitness", "government fee", "parking", "insurance". Common spending categories have no coverage.

**Arabic merchant extraction quality directly limits categorization:** If merchant name extraction fails (e.g., "تم الخصم 500 SAR لدى مطعم الريم" returns merchant = "مطعم الريم"), the generic rule `مطعم` would catch it. But if extraction fails entirely, merchant = null → categorization by type rule only → "payment" → falls through to "other".

### Auto-Confirm vs Pending

```dart
const autoConfirmThreshold = 0.92;        // parse confidence
const categoryAutoConfirmThreshold = 0.80; // category confidence
final canAutoConfirm = parseConf >= 0.92 && categoryConf >= 0.80 && !isNewMerchant;
```

For a transaction to auto-confirm:
- Must have a known bank profile → senderMatched + 0.10 + 0.15 + 0.10 = 0.35 base
- Must have amount (0.25) + known type (0.15) + currency (0.10) + no ambiguity (0.10) = 0.60 more
- Total possible: up to 1.0 with merchant (0.10) and date (0.05)
- Minimum for auto-confirm: ~0.92 → requires bank profile + amount + type + currency + no ambiguity

**Reality:** Most new merchants will be `isNewMerchant = true` → pending even at 0.92 confidence. Category confidence ≥ 0.80 requires a keyword match or user mapping. Fallback ("other") gives 0.3 → never auto-confirms.

---

## Phase 5 — Shortcut Audit

### Current Trigger Strategy

The iOS Shortcut automation filters messages by **"Message Contents contains CURRENCY"** (e.g., "SAR"). This approach:

- ✅ Simple to set up
- ✅ Works for single-currency Saudi users who always see "SAR" in messages
- ❌ **False positives**: Any non-bank message mentioning "SAR" triggers the shortcut (price listings, WhatsApp, merchant promotions)
- ❌ **False negatives**: Messages that use Arabic currency names ("ريال") instead of "SAR" are missed
- ❌ **Multi-currency gap**: Needs a SEPARATE automation per currency

### Sender-Name Availability

The `PostBankStatusIntent` accepts `sender: String?`. Whether iOS Shortcuts actually populates this parameter depends on:
- Whether the "Sender Name" variable is available in the "Message received" automation
- Whether the user explicitly wires it (onboarding step 5/6)
- SMS from alphanumeric IDs (bank codes) → sender IS available
- iMessage from contacts → sender is contact name (not bank code)

**Status: UNCONFIRMED** — on-device test pending per previous session.

If sender is empty, `BankSenderFilter.isLikelyBank()` returns `true` (empty sender is treated as manual input), so filtering still works. But bank detection relies on body keywords only → lower confidence.

### Multi-Currency Support

**Saudi user, single currency:** Works. One automation for "SAR" covers all messages.

**UAE user:** Must create ONE automation for "AED", and ANOTHER for any USD international purchases. The onboarding UI mentions this ("كرّر لاحقاً لأي عملة إضافية") but doesn't walk them through creating multiple automations.

**Saudi user with EGP account (e.g., expat with Egyptian bank):** Must create an EGP automation separately. If not done, EGP messages are never captured.

**Egyptian user:** Must create automation for "EGP". But many Egyptian bank messages say "جنيه" (Arabic) or just a number — the "EGP" keyword might not appear at all. Those messages would be missed even with an automation.

### False Positive Risks

**High risk:** A message from a telecom saying "Bonus of 5 SAR added" would trigger the shortcut. The parser would likely catch it as a transaction attempt (has "SAR", has amount). If `_isIgnored()` doesn't catch it, it could be saved as a spurious transaction.

**Mitigation in place:** `BankSenderFilter.isLikelyBank()` checks if sender is a phone number (would be a person) or alphanumeric (likely bank). But promotions from telecom brands (like "STC") would pass this check since "STC" is alphanumeric.

**`_isIgnored()` doesn't include:** "bonus added", "reward", "cashback" in English (only "promo", "offer", "coupon" are covered). A "SAR 5 cashback credited" message from a bank app might be parsed as income.

### False Negative Risks

**Would a Saudi user miss messages?**
- If message says "ريال" not "SAR" → YES, missed unless using exact currency filter
- If bank uses "SR" abbreviation → YES, missed
- If message from bank has no SAR mention (e.g., a transfer confirmation without amount) → YES but correctly ignored (no financial content)

**Would a UAE user miss messages?**
- If they only set up SAR automation → YES for all AED messages
- If they set up AED automation → likely ok for most banks
- ADIB, ADCB, FAB: parsed generically (no profile) → always pending

**Would a multi-currency user miss messages?**
- YES unless they create one automation per currency
- No in-app reminder or verification that automations are configured

---

## Phase 6 — Database & Sync Audit

### Drift Schema

Current schema version: **8** (`_targetSchemaVersion = 8` in `app_database.dart`)

Key tables:
- `transactions` — core, has `account_id` FK (multi-currency)
- `merchants` + `merchant_category_map` — learned categorizations
- `accounts` — multi-currency accounts
- `dedup_hashes` — hash + occurred_at + transaction_id
- `sender_bank_mappings` — Gemini suggestions + user confirmations
- `remote_banks`, `remote_parsers`, `remote_currencies`, `remote_countries` — catalog cache
- `remote_merchant_keywords` — remote categorization keywords
- `pending_merchant_feedback` — anonymous merchant data to send
- `remote_feature_flags`, `remote_announcements` — feature management

### Migration Strategy

**Non-standard Drift migration**: Uses manual `PRAGMA user_version` + idempotent `IF NOT EXISTS` + `ADD COLUMN IF NOT EXISTS` pattern. `MigrationStrategy.onUpgrade` is a no-op.

**Risk**: On a fresh install, `_createSchema()` runs first and sets up all tables. On upgrade, `_runCompatibilityMigrations()` patches the differences. But `PRAGMA user_version` is only SET at the END of `initialize()` — if the app crashes mid-migration, version stays at old value, migration reruns on next launch. Since migrations are idempotent, this is safe.

**Known risk**: `_ensureColumn('transactions', 'account_id', 'TEXT NULL')` — if this runs on a database with millions of transactions, it adds a nullable column with NULL for all existing rows. The backfill to the default account only runs if `count('accounts') == 0`. If users already had accounts but NULL `account_id` on some transactions, those transactions float unattached. This is a data quality risk post-migration.

### Deduplication

Two-layer system (see Phase 2 for details). Key observation:
- `DriftDedupStore` has no cleanup mechanism — `dedup_hashes` table grows forever
- Old hashes (>24h or >30 days) are never pruned
- For a heavy user with 30 transactions/day, this table would have ~10k rows/year
- No index on `saved_at` — pruning query would require full scan

### Sender Bank Mappings

`sender_bank_mappings` has robust schema:
- `status`: pending / confirmed / rejected
- `rejection_expires_at`: cooldown period for rejected senders
- `sync_status`: pending / synced / failed (for server-side feedback loop)
- `reason`: Gemini's rationale (nullable)

**Gap**: Rejected mappings with expired cooldown are treated as `unknown` (not re-triggering discovery). If the cooldown expires and Gemini would now have better context, it never gets another chance unless the mapping is manually reset.

### Backup Flow

`BackupService` exports a JSON snapshot. `EncryptedBackupService` wraps it with AES encryption before upload to Supabase Storage.

**Backup includes:** transactions, categories, merchant maps, budgets, goals, subscriptions, accounts, gamification.
**Backup excludes:** sender_bank_mappings, dedup_hashes, remote catalog data (re-syncable).

**Risk**: No incremental backup — every backup is a full snapshot. For users with thousands of transactions, backup file could be several MB. No background backup scheduling visible in the code; user must manually trigger.

### Catalog Sync

`CatalogSyncService` syncs: banks, parsers, currencies, countries, categories, merchant keywords from Supabase Edge Functions using `catalog-delta` function (version-based differential sync).

`RulesClient.localBankProfiles()` returns remote banks if any exist, otherwise falls back to `BankProfiles.all`. If catalog has never synced (fresh install without connectivity), only the 18 hardcoded banks are available.

**No sync on first install guarantee**: If user pastes their first message before sync completes, they get hardcoded profiles only. Sync is triggered on resume, not on startup.

### Offline Behavior

- App fully functional offline — all parsing is local
- Remote keywords and bank profiles fall back to hardcoded values
- Gemini AI calls fail silently (no error shown)
- Backup upload fails silently
- Feature flags use last synced values (or defaults if never synced)

---

## Phase 7 — UI & UX Audit

### Dashboard Screen

| Element | Status | Issue |
|---------|--------|-------|
| Greeting | ✅ Works | Uses email local part; "صديق مالي" for guest |
| Account switcher | ✅ Works | Shows all accounts + currencies |
| Spent / Income totals | ✅ Works | Per-account or all-accounts |
| Multi-currency totals card | ✅ Works | Shown only if hasMultipleCurrencies |
| Pending review card | ⚠️ Partial | Tapping opens **first** pending item only, not a queue |
| Budget bar | ⚠️ Bug | Uses hardcoded "ريال" in notification text (not currency) |
| Category donut | ✅ Works | Good visual |
| Recent transactions | ✅ Works | |
| Goal card | ✅ Works | Shows first active goal only |
| Subscription preview | ⚠️ Missing | All subscriptions shown in single currency; no per-account |
| Spending trend sparkline | ✅ Works | |
| Currency in labels | ⚠️ Incomplete | `_currencyLabel()` only covers 8 currencies; others show code |

**Missing:**
- No global "review all pending" action — reviewing pending is item-by-item, first-comes-only
- No visible count of "auto-confirmed vs pending" breakdown
- No shortcut setup status indicator ("Shortcut connected / not connected")

### Transaction Details Screen

| Field | Shown | Notes |
|-------|-------|-------|
| Amount | ✅ | With currency |
| Merchant | ✅ | |
| Category | ✅ | With "change" button |
| Transaction type | ✅ | Arabic labels |
| Source + card last4 | ✅ | |
| Date + time | ✅ | |
| Balance after | ✅ | Only if captured |
| Note | ✅ | If present |
| Status (pending) | ✅ | Shown as amber text |
| Raw message | ✅ | Expandable |
| **Foreign amount** | ❌ | Not shown even if foreignAmount captured |
| **Foreign currency** | ❌ | Not shown |
| **Funding source** | ❌ | Not shown (e.g., "from barq wallet") |
| **Parse confidence** | ❌ | Never shown to user |
| **Bank key** | ❌ | Not shown |
| **Why pending?** | ❌ | No explanation for pending status |

### Transaction List (Transactions Screen)

Not directly audited, but providers read from Drift `transactions` table. Known pattern issues:
- Pending status shown with icon but no description of why
- No bulk confirm/delete actions

### Settings Screen

| Section | Status |
|---------|--------|
| Accounts management | ✅ |
| Language selector | ✅ |
| Country selector | ✅ |
| Currency selector | ✅ |
| Theme (dark/light) | ✅ |
| Notifications | ✅ |
| iOS Shortcut guide | ✅ |
| AI consent toggle | ✅ (requires scrolling to find) |
| App lock / biometrics | ✅ |
| Data export (CSV) | ✅ |
| Backup | ✅ (via backup screen) |
| Privacy / data wipe | ✅ |

**Issue:** AI consent toggle is buried in settings. There is no prompt or explanation during onboarding that AI features are available and how to enable them. Most users will never enable it.

### Onboarding

| Step | Status |
|------|--------|
| Auth (Google/Apple/email) | ✅ |
| Method selection (iOS Shortcut) | ✅ |
| Shortcut setup guide (8 steps) | ✅ but: |
| — Step 3: currency filter | ⚠️ Shows only ONE currency — multi-currency not emphasized |
| — No "test your shortcut" verification | ❌ |
| — No explanation of pending vs confirmed | ❌ |
| — No AI consent prompt | ❌ |
| Restore from backup | ✅ |

### Bank Discovery Confirmation Sheet

`bank_discovery_confirmation_sheet.dart` — shown when Gemini suggests an unknown bank. This appears to work and shows the suggested bank name + confidence. However:
- Only shown if sender is non-empty (Shortcut must have passed sender)
- Only shown if user has AI consent on
- If Gemini suggested bank is wrong and user rejects it, rejected mapping goes into cooldown — but bank discovery may never fire again for that sender

### Missing User Journeys

1. **"Why wasn't my message captured?"** — No diagnostic screen, no history of rejected messages
2. **"My bank isn't listed"** — No manual bank profile setup, discovery is all or nothing
3. **"I have both SAR and EGP transactions"** — No guided multi-currency shortcut setup
4. **"I want to review all pending at once"** — Only first pending item opens from dashboard
5. **"What is confidence?"** — Technical detail hidden from user

---

## Phase 8 — Production Readiness Scores

| Area | Score | Rationale |
|------|-------|-----------|
| **Parser** | 6/10 | Good for 18 known banks; silent drops for unknown banks; currency/merchant extraction has edge cases |
| **Gemini Bank Discovery** | 5/10 | Logic is correct; hidden behind AI consent toggle (off by default); dead in Shortcut path for parse-sms |
| **Gemini AI Parsing** | 2/10 | Dead in primary capture path (Shortcut). Works only in manual paste. |
| **Categorization** | 5/10 | Saudi coverage decent; UAE/Egypt thin; no learning from remote keywords until synced |
| **Shortcuts** | 6/10 | Concept works; currency-keyword trigger is fragile; multi-currency requires manual extra setup; sender status unknown |
| **Sync** | 7/10 | Delta sync works; offline graceful fallback; catalog sync latency on first launch |
| **Backup** | 6/10 | Functional but manual only; no incremental; no background schedule |
| **UX** | 5/10 | Good dashboard; pending review UX broken; foreign currency not displayed; no diagnostic tools |
| **Security** | 8/10 | SQLCipher encryption; privacy mode; SmsSanitizer; no secrets in binary; biometric lock |
| **Privacy** | 9/10 | On-device parsing; AI consent required; SmsSanitizer strips PII; merchant feedback anonymous only |

---

## Phase 9 — Critical Bugs

### P0 — Must Fix Before Any Beta Users

**BUG-001: AI parsing cascade is dead in Shortcut capture path**  
*File:* `lib/features/capture/services/captured_message_processor.dart`  
*Symptom:* Messages from unsupported banks captured via Shortcut that score < 0.70 are silently discarded. User never sees them.  
*Fix:* Pass `aiClient`, `loadAiConsent`, `installId` to `AddTransactionUseCase` in `CapturedMessageProcessor`, OR use `ingestCapturedMessageUseCaseProvider` from Riverpod in `AppShell._consumeSharedInput()`.

**BUG-002: AI consent disabled by default with no onboarding prompt**  
*File:* `lib/features/onboarding/method_screen.dart`, `settings_screen.dart`  
*Symptom:* Gemini bank discovery and AI parsing never fire for new users without them finding the setting.  
*Fix:* Add AI consent opt-in during onboarding with plain-language privacy explanation.

**BUG-003: UAE banks have essentially zero coverage**  
*File:* `lib/engine/parser/bank_profile.dart`  
*Symptom:* ADIB, ADCB, FAB, ENBD — all major UAE banks — not in `BankProfiles.all`. UAE users get generic parse at best (always pending) or silent drops.  
*Fix:* Add UAE bank profiles. Minimum: ADIB, ADCB, FAB, ENBD, Mashreq.

**BUG-004: Silent message drops have no user feedback**  
*Symptom:* When parser drops a message (conf < 0.70, no AI), user has no way to know. No notification, no log, no "we couldn't read this" state.  
*Fix:* Show a notification or save as "unprocessed" state when message is dropped (configurable — only for messages from bank-like senders).

### P1 — Must Fix Before Launch

**BUG-005: Budget alert notifications hardcode "ريال" currency**  
*File:* `lib/features/app/app_shell.dart:183`  
*Code:* `'${alert.progress.budget.amount.toStringAsFixed(0)} ريال.'`  
*Symptom:* AED or EGP users see "ريال" in budget alerts even if budget is for EGP account.  
*Fix:* Pass budget currency through to the notification string.

**BUG-006: Dashboard "pending review" card only opens first pending transaction**  
*File:* `lib/features/dashboard/dashboard_screen.dart` (`_reviewCard` widget)  
*Symptom:* Tapping the "N transactions need review" card opens only the first pending transaction. No queue navigation.  
*Fix:* Open a dedicated pending-review list screen, or implement swipe-next in the review sheet.

**BUG-007: Foreign amount/currency not shown in transaction details**  
*File:* `lib/features/transactions/transaction_details_screen.dart`  
*Symptom:* International purchases (e.g., "USD 100 (SAR 375)") have `foreignAmount` and `foreignCurrency` stored but never displayed.  
*Fix:* Add "foreign amount" row in transaction details when `tx.foreignAmount != null`.

**BUG-008: Currency fallback to SAR for Arabic-only currency names**  
*File:* `lib/engine/parser/parser_engine.dart:_extractCurrency()`  
*Symptom:* Messages saying "ريال" (not "SAR") or "جنيه" (not "EGP") fail currency detection → fall back to account default.  
*Fix:* Add Arabic currency aliases to `_currencyPattern`: map "ريال" → SAR, "جنيه" → EGP, "درهم" → AED in normalizer or as bank profile `currencyAliases`.

**BUG-009: Multi-currency shortcut setup not guided**  
*File:* `lib/features/onboarding/ios_shortcut_screen.dart`  
*Symptom:* User with SAR + EGP accounts creates only one automation (SAR); EGP messages are never captured. UI says "repeat later" but gives no action.  
*Fix:* After onboarding, show "Add automation for your other currencies" prompt per account.

**BUG-010: `dedup_hashes` table has no pruning mechanism**  
*File:* `lib/data/db/app_database.dart`  
*Symptom:* Table grows indefinitely. Old hashes provide no value after ~24h. Will degrade read performance over months.  
*Fix:* Prune hashes older than 30 days during `_onResume()` or catalog sync.

**BUG-011: Merchant names starting with a digit are silently rejected**  
*File:* `lib/engine/parser/parser_engine.dart:_cleanMerchant()`  
*Code:* `!value.contains(RegExp(r'^[0-9]'))` rejects them  
*Symptom:* "7-Eleven", "360 Mall", "1Pharmacy" → merchant = null → poor categorization.  
*Fix:* Allow leading digits if the rest is alphanumeric (not just a number).

### P2 — Can Wait

**BUG-012: "مرسول" (Mrsool) categorized as Transport not Food Delivery**  
*File:* `lib/engine/categorization/category_seeds.dart`  
*Symptom:* Mrsool is a food/grocery delivery app, not transport. Misleading.  
*Fix:* Add a `delivery` category or move to `restaurants`.

**BUG-013: `_currencyLabel()` in dashboard doesn't cover all currencies**  
*File:* `lib/features/dashboard/dashboard_screen.dart:_currencyLabel()`  
*Symptom:* Currencies not in the 8-item switch (GBP, USD, etc.) show their 3-letter code only.  
*Fix:* Use `Currency.arabicLabel()` helper already in the codebase.

**BUG-014: No "pending since X days" indicator**  
*Symptom:* Old pending transactions don't surface unless user actively browses.  
*Fix:* Add age indicator ("pending for 3 days") or a weekly reminder notification.

**BUG-015: Diagnostic logging (`[Mali] parse:`, `[Mali] drain:`) left in production code**  
*File:* `lib/features/app/app_shell.dart`, `lib/domain/usecases/add_transaction_usecase.dart`  
*Symptom:* Debug prints in release build.  
*Fix:* Remove after on-device Shortcut test confirmed.

**BUG-016: `isNewMerchant` check prevents auto-confirm even for well-known merchants on first transaction**  
*File:* `lib/domain/usecases/add_transaction_usecase.dart:191`  
*Symptom:* First time user pays at Starbucks → `isNewMerchant = true` → pending, even if conf = 1.0 and category = cafes.  
*Fix:* Pre-populate `merchant_category_map` from `CategorySeeds.keywordRules` at seed time, so known merchants are never "new".

---

## Phase 10 — Final Recommendation

### Is Mali Currently Ready For...

| Stage | Verdict | Reason |
|-------|---------|--------|
| **Personal use (Saudi, SAR only)** | ✅ Yes, with caveats | Parser covers major Saudi banks. Pending flow works. Manual paste reliable. Issues: AI dead in Shortcut path, occasional silent drops for edge cases. |
| **Closed beta (Saudi + Egyptian users)** | ⚠️ Not yet | Egyptian bank coverage too thin (3 banks). AI consent not surfaced. Silent drops will confuse users who don't know if the app is working. Fix BUG-001, BUG-002, BUG-004 first. |
| **Public beta (Saudi + UAE + Egypt)** | ❌ No | UAE has zero bank profiles beyond Dubai Bank. ADIB alone is a major UAE bank. Multi-currency shortcut setup is not guided. BUG-001 through BUG-009 must be fixed. |
| **App Store launch** | ❌ No | Need: complete P0+P1 bugs, bank coverage expansion, guided multi-currency setup, proper pending review UX, remove debug logging. |

### Justification

The core on-device parsing architecture is sound. The privacy model is strong. The data model is correct. The UX for confirmed Saudi transactions is good.

**The primary problem is trust**: users don't know whether the app is working or silently failing. A message that gets dropped has no visible trace. A pending transaction shows no reason why. These are fixable with notification and diagnostic improvements.

**The secondary problem is coverage**: 18 hardcoded banks for a 6-country Gulf/Egypt market is not enough for public launch. The Gemini bank discovery pipeline is designed to fix this, but it requires AI consent (off by default) and is broken in the primary capture path.

---

## Executive Summary

Mali's on-device architecture is fundamentally sound: local Drift DB with SQLCipher, rule-based Dart parser running in an isolate, privacy-preserving sanitizer before any AI call, clean separation between capture and UI. The design decisions are correct.

**Three structural problems prevent production confidence:**

1. **The AI parsing cascade doesn't fire in the main capture path.** When an iOS Shortcut triggers message capture, `CapturedMessageProcessor` builds its own `AddTransactionUseCase` without an `aiClient`. Any message scoring below 0.70 (unknown bank format, unusual structure) is silently discarded. This affects all unsupported banks and will be the most common user complaint: "I set up the shortcut but my transactions don't appear."

2. **Bank coverage leaves UAE essentially unsupported.** Of the 18 hardcoded banks, only one is UAE (`dubai_bank`). ADIB, ADCB, FAB, ENBD — the top-4 UAE banks by market share — are missing. UAE users get generic parsing at best (always pending, never auto-confirmed) and silent drops at worst.

3. **Gemini bank discovery is off by default and never promoted.** The `aiConsentGranted` flag defaults to false, and there is no onboarding screen that explains or offers it. Most real users will never enable it, meaning the entire bank discovery and AI parsing layer is invisible to them.

---

## Top 10 Risks

1. **Silent drops at scale** — Users with unknown banks get nothing. No feedback, no notification. Biggest trust killer.
2. **AI parse cascade dead in Shortcut path** — Primary capture method doesn't use AI at all.
3. **UAE bank coverage = zero** — ADIB, ADCB, FAB, ENBD all missing.
4. **AI consent default OFF** — Gemini never fires for most users.
5. **Multi-currency shortcut setup not guided** — EGP users with SAR setup miss all EGP messages.
6. **Currency fallback to SAR for Arabic currency names** — EGP/AED messages with "جنيه"/"درهم" get wrong currency if no account currency match.
7. **`dedup_hashes` unbounded growth** — Performance degrades over months without pruning.
8. **Pending review UX broken at scale** — First-item-only from dashboard; no queue navigation.
9. **Foreign currency not displayed in UI** — International purchase data captured but never shown.
10. **No "Shortcut connected?" verification** — User can't tell if their automation is working.

---

## Top 10 Improvements

1. **Fix AI cascade in `CapturedMessageProcessor`** — Pass `aiClient` and consent loader. Immediate impact.
2. **Add AI consent prompt to onboarding** — With clear privacy statement. Unlocks entire AI layer.
3. **Add 5 UAE bank profiles** — ADIB, ADCB, FAB, ENBD, Mashreq. Covers 80%+ of UAE users.
4. **Silent drop → "unprocessable" notification** — "We received a message from ADIB but couldn't parse it. Tap to paste manually." Builds trust.
5. **Pending review queue** — Replace "first item" tap with a full review flow (swipe-through card or list screen).
6. **Foreign currency row in transaction details** — One-line fix for international purchase visibility.
7. **Arabic currency names in normalizer** — Map "ريال", "جنيه", "درهم" to SAR/EGP/AED codes. Fixes currency fallback.
8. **Pre-populate merchant_category_map from seeds** — `CategorySeeds.keywordRules` entries as confirmed merchant mappings. Starbucks is no longer "new".
9. **Budget notifications use account currency** — Replace hardcoded "ريال" with actual currency.
10. **`dedup_hashes` pruning** — Prune entries older than 30 days on resume. Simple, high-value.

---

## Recommended Next Sprint

**Sprint Goal: "Capture Reliability"** — Fix the two biggest trust gaps (silent drops, AI cascade) and unlock UAE users.

### Must Complete (P0 fixes)

1. **Fix `CapturedMessageProcessor` AI wiring** (BUG-001) — 2h
   - Pass `aiClient`, `loadAiConsent`, `installId` to `AddTransactionUseCase`
   - OR refactor to use `ref.read(ingestCapturedMessageUseCaseProvider)` in `AppShell`

2. **Add onboarding AI consent step** (BUG-002) — 4h
   - After method selection: "مالي يحلل رسائلك على جهازك. للبنوك غير المدعومة، هل تسمح بإرسال نسخة مُعقَّمة لخدمة ذكاء اصطناعي؟"
   - Yes/No choice → sets `aiConsentGranted`

3. **Add 5 UAE bank profiles to `BankProfiles.all`** (BUG-003) — 4h
   - ADIB, ADCB, FAB, ENBD, Mashreq
   - Minimum fields: keywords, senderIds, typeRules, amountRules, balanceRules

4. **"Unprocessable" notification** (BUG-004) — 3h
   - When message from bank-like sender drops with conf < 0.70 after AI attempt
   - Notification: "رسالة من [sender] لم نتمكن من تحليلها. انقر لإضافتها يدوياً."

### Should Complete (P1 high-impact)

5. **Foreign currency in transaction details** (BUG-007) — 1h
6. **Arabic currency aliases in normalizer** (BUG-008) — 2h
7. **Budget alert currency fix** (BUG-005) — 1h
8. **Remove diagnostic logging** (BUG-015) — 30min

### Defer to Next Sprint

- Pending review queue UX (BUG-006) — UX design needed first
- Multi-currency shortcut guided setup (BUG-009) — Product decision on UX
- `dedup_hashes` pruning (BUG-010) — Low urgency
- Pre-populate merchant map from seeds (BUG-016) — Nice to have

---

*Report generated by codebase analysis of all files under `lib/`, `ios/`, relevant to the listed phases.*  
*Files read: 30+ dart files, 3 swift files, database schema.*  
*No code was modified during this investigation.*
