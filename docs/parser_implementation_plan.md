# Mali Parser — Implementation Plan

**Based on:** `mali_parser_buildspec.md` audit vs. existing codebase  
**Date:** June 2026  
**Status:** Awaiting owner approval before any implementation begins

---

## Part 1 — Audit: What Exists vs. What the Spec Requires

### 1.1 Existing engine files

| File | Lines | Role |
|------|-------|------|
| `engine/parser/normalizer.dart` | 60 | Digit normalization + currency alias normalization |
| `engine/parser/bank_profile.dart` | 165 | BankProfile data class + BankProfiles registry |
| `engine/parser/parser_engine.dart` | 664 | Single engine: ignore filter, type detection, amount extraction, merchant, date, confidence |
| `engine/parser/amount_candidate.dart` | 27 | AmountCandidate kind/score data class |
| `engine/parser/parse_result.dart` | 33 | ParseResult wrapper |
| `engine/parser/parser_isolate.dart` | 74 | Dart isolate runner |
| `engine/categorization/categorizer.dart` | 70 | Priority chain: userMap → typeRule → keyword → fallback |
| `engine/categorization/category_seeds.dart` | 70 | ~50 hardcoded merchant keyword → category key mappings |
| `engine/categorization/merchant_category_map.dart` | 34 | Local learned map (user corrections) |
| `engine/models/parsed_transaction.dart` | 60 | ParsedTransaction DTO |
| `engine/models/transaction_type.dart` | 12 | 6-value TransactionType enum |
| `test/engine/fixtures/bank_sms_golden_fixtures.dart` | 278 | 12 golden fixtures (10 positive + 2 gate) |

### 1.2 Component-by-component gap analysis

| Component | Status | Notes |
|-----------|--------|-------|
| Normalization — Eastern digits | ✅ Exists | |
| Normalization — currency aliases | ✅ Exists | ر.س, ج.م, ريال, درهم, etc. |
| Normalization — thousands separator strip | ❌ Missing | `18,000.00` fails |
| Normalization — glued-currency detection | ❌ Missing | `60.00EGP`, `21.00SAR`, `300.56ر.س` handled partially by chance, not by design |
| Normalization — hamza normalization | ❌ Missing | Not needed for amount/currency; relevant for keyword matching edge cases |
| Normalization — tashkeel strip | ❌ Missing | Minor; add for safety |
| Ignore filter — OTP / promo / links | ✅ Exists | Inside `parser_engine.dart` |
| Ignore filter — admin/security notices | ❌ Missing | "حسابك مجمد", "تسجيل خروج", complaint closed — not caught |
| Ignore filter — runs on raw text | ❌ Missing | Spec requires OTP check on pre-normalized text |
| Bank detection — sender ID matching | ✅ Exists | |
| Bank detection — body keyword fallback | ✅ Exists | |
| BankProfile — `feeRules` field | ❌ Missing | Need to classify fee lines as ignore |
| BankProfile — `totalDueRules` field | ❌ Missing | `المبلغ الإجمالي المستحق` — ignore as amount |
| BankProfile — `currencyDecimals` | ❌ Missing | KWD/BHD/OMR = 3 decimal places |
| BankProfile — Saudi banks (SNB, Rajhi, Riyad, STC) | ✅ Exists | Basic only — missing SAIB, ANB, BSF, Albilad, Aljazira, D360, barq |
| BankProfile — Egypt (CIB, NBE, Banque Misr, QNB) | ✅ Exists | Basic only |
| BankProfile — UAE / Gulf | ❌ Missing | Emirates/Dubai Bank not added yet |
| Amount extraction — label-based (`مبلغ:`, `Amount:`) | ✅ Exists | |
| Amount extraction — `بقيمة` label | ❌ Missing | Bank Aljazira |
| Amount extraction — `مبلغ العملية:` label | ✅ Exists | |
| Amount extraction — international `FOREIGN (LOCAL)` | ❌ Missing | Must extract LOCAL from parentheses |
| Amount extraction — thousands comma strip | ❌ Missing | `18,000.00` → `18000.00` |
| Amount extraction — glued currency (`21.00SAR`) | ⚠️ Partial | Works by chance; needs explicit handling |
| Balance labels — `الرصيد المتاح:` | ✅ Exists | |
| Balance labels — `الرصيد المتوفر:` | ❌ Missing | BSF sample |
| Balance labels — `رصيد:` | ❌ Missing | Dubai Bank |
| Balance labels — `Wallet balance:` | ✅ Exists via `balance` keyword | |
| Fee / ignore labels — `الرسوم/الضريبة:`, `رسوم العملية:`, `Fee:` | ⚠️ Partial | `Fee:` near-keyword works; Arabic fee labels not explicitly classified |
| Total-due ignore — `المبلغ الإجمالي المستحق` | ❌ Missing | BSF fixture — would be extracted as amount |
| Merchant labels — `لدى`, `At`, `اسم التاجر:` | ✅ Exists | |
| Merchant labels — `عند` | ✅ Exists | Added this session |
| Merchant labels — `إلى:` / `To:` (transfer beneficiary) | ✅ Exists | |
| Merchant labels — `الجهة:` (government payee) | ❌ Missing | ANB traffic fine |
| Funding-wallet exclusion — `barq` ≠ merchant | ❌ Missing | CONFLICT — see Section 2 |
| Date — ISO-8601 (`YYYY-MM-DD`) | ✅ Exists | |
| Date — `DD/MM/YY` + time | ✅ Exists | |
| Date — `DD/MM` no year | ✅ Exists | Added this session |
| Date — `YY-MM-DD` (ANB style `26-06-15`) | ❌ Missing | |
| Date — `M/D/YYYY` (STC `3/9/2026`) | ❌ Missing | |
| Date — `DD-MM-YYYY` (Dubai `24-01-2025`) | ❌ Missing | |
| Date — time suffix `HH:MM:SS` | ❌ Missing | SAIB `09:09:19` — extra seconds |
| Confidence engine | ✅ Exists | Weights, thresholds, generic cap 0.79, AI cap 0.69 |
| Dedup (SHA-256) | ❌ Missing | Not implemented anywhere |
| Categorization — keyword rules | ✅ Exists | ~50 keywords, Saudi-focused |
| Categorization — Egypt merchants | ❌ Missing | Fawry, Vodafone Cash, Orange, Talabat Egypt, etc. |
| Categorization — delivery apps | ❌ Missing | HungerStation, Talabat, Mrsool, جاهز |
| Categorization — funding-wallet exclusion | ❌ Missing | barq/STC Pay as source should not be categorized |
| Categorization — remote admin dictionary | ❌ Missing | Spec says NOT hardcoded; should be remote catalog |
| AI fallback | ❌ Missing | Not implemented |
| `ParsedTransaction` — `foreignAmount` field | ❌ Missing | For international transactions |
| `ParsedTransaction` — `foreignCurrency` field | ❌ Missing | |
| `TransactionType` — `creditCardPayment` | ❌ Missing | Dubai Bank "تأكيد السداد" |
| `TransactionType` — `governmentPayment` | ❌ Missing | ANB traffic fines |
| Golden corpus — ignore fixtures | ❌ Missing | 3 real ignore samples from spec not yet in corpus |
| Golden corpus — new real bank fixtures | ❌ Missing | 13 new samples from spec not yet added |
| Golden corpus — ambiguous amount fixture file | ❌ Missing | BSF 3-amount case not yet a test |

---

## Part 2 — CONFLICTS: Spec vs. Existing Tests

These existing golden tests conflict with what the spec now says. They must be updated — existing expected values are wrong per the new spec.

### Conflict 1 — Funding wallet as merchant (`barq`)

**Fixtures affected:**
- `sa_ar_online_purchase_account_masked` → `expectedMerchant: 'barq'`
- `sa_ar_online_purchase_fee_zero` → `expectedMerchant: 'barq'`
- `sa_en_online_purchase_account_and_card` → `expectedMerchant: 'barq'`

**Spec says (Section 5, point 4):** "`من:barq` / `At barq` is the payment source, not the merchant."

**Resolution:** These three fixtures need `expectedMerchant: null` (or optionally a specific `expectedFundingSource: 'barq'` if we add that field). The parser needs a funding-wallet deny-list: `{'barq', 'urpay', 'stcpay', 'stc pay'}` — if the extracted merchant is in this list and the merchant label is `من:` or `At`, treat it as a funding source and set merchant = null.

**Decision needed from owner:** should we expose `fundingSource` as a new field on `ParsedTransaction`, or just set merchant = null?

### Conflict 2 — International amount: foreign vs. local

**Fixtures affected:**
- `sa_international_online_purchase_fee_balance` → `expectedAmount: 4.91, expectedCurrency: 'USD'`
- `kwd_international_purchase_fx_wallet_balance` → `expectedAmount: 0.1, expectedCurrency: 'KWD'`

**Spec says (Section 5, point 3):** "Format `FOREIGN (LOCAL)` e.g. `USD 4.91 (SAR 18.44)` → take the LOCAL amount in parentheses."

**Resolution:** These fixtures need updating to `expectedAmount: 18.44, expectedCurrency: 'SAR'` (D360) and `expectedAmount: 1.22, expectedCurrency: 'SAR'` (barq KWD). The spec also says "store foreign amount + currency in separate fields" — so `ParsedTransaction` needs `foreignAmount` + `foreignCurrency` fields. The existing tests will also need `expectedForeignAmount` + `expectedForeignCurrency` fields added to `BankSmsGoldenFixture`.

**Decision needed from owner:** confirm the preferred behavior (local amount in body, foreign stored as metadata).

---

## Part 3 — Implementation Plan (Phase by Phase)

### Phase 0 — Owner approval of this plan (you are here)

No code written yet. Once approved, implementation begins at Phase 1.

---

### Phase 1 — Foundation fixes (normalization + ignore + models)

**Goal:** make the foundational layers correct before adding more bank profiles on top of a weak base.

#### 1-A. `engine/models/parsed_transaction.dart`

Add two new optional fields:
```
foreignAmount: double?      // original amount before FX conversion
foreignCurrency: String?    // original currency before FX conversion
```

No other changes. Existing code is forward-compatible (both fields nullable).

#### 1-B. `engine/models/transaction_type.dart`

Add two new enum values:
```
creditCardPayment   // "تأكيد السداد" — card bill payment
governmentPayment   // "مدفوعات وزارة الداخلية" — bill payment to government
```

Both are expenses for budget purposes (`isExpense` returns true for both).

#### 1-C. `engine/parser/bank_profile.dart` — extend `BankProfile`

Add three new fields to the class and all constructors:
```dart
final List<String> feeRules       // labels that precede fees (classify as fee, not amount)
final List<String> totalDueRules  // labels for total-due amounts (ignore as transaction amount)
final int currencyDecimals        // 2 for most, 3 for KWD/BHD/OMR
final List<String> fundingWallets // sender aliases that are payment sources, not merchants
```

#### 1-D. `engine/parser/normalizer.dart`

Add to the `normalize()` method (before currency normalization):
1. **Thousands comma strip:** `text.replaceAll(RegExp(r'(\d),(\d{3})'), r'$1$2')` — handles `18,000.00` → `18000.00` and Arabic `٬` separator
2. **Tashkeel strip:** remove Arabic diacritics (Unicode range U+064B–U+065F, U+0670)

No behavioral changes to existing normalization steps.

#### 1-E. `engine/parser/parser_engine.dart` — surgical fixes

Five targeted changes (no structural rewrite):

1. **International amount pattern** — add regex for `FOREIGN_AMOUNT (LOCAL_AMOUNT)`:
   ```
   static final RegExp _intlParens = RegExp(
     r'([A-Z]{3})\s*([\d,.]+)\s*\((([A-Z]{3})\s*([\d,.]+))\)',
   );
   ```
   When matched: transaction amount = inner (local) amount + currency; foreign = outer.

2. **Fee/total-due label classification** — in `_classifyAmountCandidate`, add to the feeWords list:
   - Arabic: `الرسوم/الضريبة`, `رسوم العملية`, `الرسوم`, `الضريبة`
   - `المبلغ الإجمالي المستحق` → add to a new `totalDueWords` list (classified as `referenceNumber` kind to suppress it)

3. **Balance labels** — add to the balanceWords list:
   - `الرصيد المتوفر`, `رصيد:`, `wallet balance`

4. **Date formats** — add three new patterns in `_extractDate` (tried in order after existing patterns):
   - `YY-MM-DD` (ANB): `\b([0-9]{2})-([0-9]{2})-([0-9]{2})\b` → interpret first group as 20YY
   - `M/D/YYYY` (STC): already matched by `_dateTimeDmy` with day=3, month=9 when input is `3/9/2026` — **BUT** this is ambiguous with `DD/MM/YYYY`. Resolution: for Saudi banks, trust the bank profile's `dateFormat` hint; for unknown senders, prefer ISO/DD-first
   - `DD-MM-YYYY` (Dubai): add explicit `\b([0-9]{1,2})-([0-9]{1,2})-([0-9]{4})\b` pattern
   - `HH:MM:SS` time — strip the seconds from SAIB timestamps: `tاريخ العملية : 2026-05-28 09:09:19` — add `:(\d{2})` as optional group 6 in the existing ISO regex, ignore seconds

5. **Merchant labels** — add:
   - `الجهة:` as merchant/payee label (government payment payee in ANB)
   - Funding-wallet exclusion: after merchant is extracted, if it matches a known funding wallet name AND the merchant-label preposition was `من` or `At` (not `إلى`/`To`/`لدى`), set merchant = null and store as `fundingSource` on result

6. **`بقيمة` amount label** — add to the `amountWords` list

#### 1-F. `test/engine/` — update conflicting fixtures and add new ones

1. Update 3 existing fixtures for funding-wallet conflict (set `expectedMerchant: null`)
2. Update 2 existing fixtures for international-amount conflict (flip to local amount)
3. Add `expectedForeignAmount` / `expectedForeignCurrency` fields to `BankSmsGoldenFixture` class
4. Add ignore fixture file: `test/engine/fixtures/ignore_fixtures.dart` (3 fixtures from spec Section 4 ignore samples)
5. Add ambiguous-amount fixture file: `test/engine/fixtures/ambiguous_amount_fixtures.dart` (BSF 3-amount case, barq KWD case)

---

### Phase 2 — New bank profiles + golden corpus

**Goal:** add all 15 banks from the real SMS samples in Section 4 and make all fixtures pass.

#### 2-A. New bank profiles to add in `bank_profile.dart`

For each bank, define: `bankKey`, `displayName`, `country`, `senderIds`, `keywords`, `typeRules`, `amountRules`, `balanceRules`, `feeRules`, `merchantRules`, `currencyDecimals`, `fundingWallets`.

| Bank | Key | Country | Sender IDs | Notes |
|------|-----|---------|-----------|-------|
| D360 | `d360` | SA | `D360`, `d360bank` | English format; local-in-parens international |
| urpay | `urpay` | SA | `urpay` | Same format as Riyad (share base profile) |
| SAIB | `saib` | SA | `saib`, `SAIB` | `مبلغ العملية:` + `الرصيد المتاح:` |
| barq | `barq` | SA | `barq`, `BARQ` | English; international local-in-parens; KWD 3-decimal |
| STC Bank | `stc_bank` | SA | `stcbank`, `STC-Bank` | Multiple message types; glued currency (`21.00SAR`) |
| ANB | `anb` | SA | `anb`, `ANB` | `بـ:SAR` pattern; `YY-MM-DD` dates; income + bill types |
| BSF | `bsf` | SA | `BSF`, `بنك فرنسا` | 3-amount messages; `المبلغ الإجمالي المستحق` as totalDue |
| Albilad | `albilad` | SA | `البلاد`, `albilad` | `مبلغ:` + `لدى:` mada-POS family |
| Bank Aljazira | `baj` | SA | `هذا الجزيرة`, `aljazira` | `بقيمة` amount label |
| Emirates/Dubai Bank | `enbd` | AE | `بنك دبي`, `dubai-bank` | Credit-card-payment type; `رصيد:` balance; `DD-MM-YYYY` |

Update existing profiles (SNB, AlRajhi, Riyad, STC Pay, CIB, NBE, Banque Misr, QNB) with:
- `feeRules` where applicable
- `fundingWallets` where applicable
- Missing `typeRules` entries (income, transfer, government for each that has them)

#### 2-B. New golden fixtures in `bank_sms_golden_fixtures.dart`

Add one fixture per real SMS sample from spec Section 4 (15 samples → 15 new fixtures):

| Fixture ID | Bank | Type | Key challenge |
|-----------|------|------|--------------|
| `eg_nbe_prepaid_fawry` | NBE | payment | Same as existing CIB fixture (was mislabeled) |
| `eg_orange_cash_en` | Orange Cash | payment | EGP before amount, @ merchant |
| `sa_rajhi_mada_pos` | Al Rajhi | payment | `بـSAR`, `لـ` merchant, `d/M/yy` date |
| `sa_d360_intl_purchase` | D360 | payment | 3 amounts: local-in-parens, fee, balance |
| `sa_riyad_online_mablag` | Riyad | payment | `مبلغ:700.00 SAR`, barq=source not merchant |
| `sa_urpay_fee_zero` | urpay | payment | Already exists; update merchant to null |
| `sa_snb_en_online` | SNB | payment | `At barq` = source; `Mada-Apple pay *5172` = card |
| `sa_saib_pos_three_amounts` | SAIB | payment | `مبلغ العملية:` vs `الرصيد المتاح:` |
| `sa_barq_kwd_intl` | barq | payment | Local in parens, KWD 3-decimal |
| `sa_stc_transfer_outward` | STC Bank | transfer | `Amount:21.00SAR` glued, `To:` beneficiary |
| `sa_anb_atm_deposit` | ANB | income | `إيداع ATM`, `بـ:SAR`, `YY-MM-DD` |
| `sa_anb_govt_payment` | ANB | governmentPayment | `مدفوعات`, `الجهة:`, `سداد`, ref number |
| `sa_bsf_pos_three_amounts` | BSF | payment | 3 amounts: txn + totalDue + balance |
| `sa_albilad_mada_pos` | Albilad | payment | `لدى:` merchant, mada |
| `sa_aljazira_biqeema` | Aljazira | payment | `بقيمة` amount label |
| `ae_dubai_card_payment` | Emirates | creditCardPayment | `تأكيد السداد`, `رصيد:`, `DD-MM-YYYY`, thousands |
| `sa_stc_income_sar_glued` | STC Bank | income | `إضافة أموال`, `ر.س` glued, `M/D/YYYY` |
| `sa_stc_transfer_arabic` | STC Bank | transfer | `حوالة`, `ر.س` glued, `إلى:` beneficiary |
| `sa_stc_intl_purchase` | STC Bank | payment | Foreign only (no local conversion) |
| `ignore_account_freeze` | — | ignored | "تم تجميد حسابك" — admin notice |
| `ignore_device_logout` | — | ignored | "تسجيل خروج أحد أجهزتك" |
| `ignore_complaint_closed` | — | ignored | "Complaint has been Closed" |

---

### Phase 3 — Categorization + dedup + merchant dictionary

#### 3-A. `engine/categorization/category_seeds.dart` — extend keyword rules

Add Egypt and Gulf merchants:
```
// Egypt
'FAWRY': bills, 'ORANGE': bills, 'TALABAT': restaurants,
'INSTAPAY': transfers, 'MRSOOL': restaurants,

// Saudi delivery
'HUNGERSTATION': restaurants, 'جاهز': restaurants, 'مرسول': restaurants,

// Gulf supermarkets
'SPINNEYS': groceries, 'WAITROSE': groceries, 'UNION': groceries,

// Generic keywords
'BUFFET': restaurants, 'RESTAURANT': restaurants, 'COFFEE': cafes,
'CAFE': cafes, 'PHARMACY': health, 'STATION': fuel,
'TAXI': transport, 'SNAP': subscriptions, 'ALIEXP': shopping,
```

Add funding-wallet keyword exclusion: `{'BARQ', 'URPAY', 'STC PAY', 'STCPAY'}` — these are never categories.

#### 3-B. SHA-256 dedup

New file: `engine/dedup/transaction_dedup.dart`

```
class TransactionDedup {
  static String hashKey(ParsedTransaction txn, {required DateTime receivedAt}) {
    // SHA-256 over: amount + currency + merchant(normalized) + card_last4 + date(rounded to hour)
    // Window: 5 minutes (same hash within 5 min = duplicate)
  }
  bool isDuplicate(String hash);    // checks Drift dedup_hashes table
  void markSeen(String hash);       // inserts into dedup_hashes table
}
```

Requires a new Drift table `dedup_hashes(hash TEXT PRIMARY KEY, seen_at INTEGER)` — bump schema version from 4 → 5.

---

### Phase 4 — AI cascade (post-launch, opt-in)

Defer until Phase 1–3 are complete and stable. Architecture already decided (Section 7 of strategy report):
- Gemini Flash as cloud fallback
- Anonymization before transmission
- Always `pending_confirmation`, never auto-confirm
- Grounding check: AI-returned amount must exist literally in source text

This phase requires: privacy consent flow, anonymization pipeline, Edge Function endpoint, rate limiting.

---

## Part 4 — File-by-File Change Summary

| File | Action | What changes |
|------|--------|-------------|
| `engine/models/parsed_transaction.dart` | CHANGE | Add `foreignAmount`, `foreignCurrency` fields |
| `engine/models/transaction_type.dart` | CHANGE | Add `creditCardPayment`, `governmentPayment` |
| `engine/parser/bank_profile.dart` | CHANGE | Add `feeRules`, `totalDueRules`, `currencyDecimals`, `fundingWallets` fields; add 10 new bank profiles; update 6 existing profiles |
| `engine/parser/normalizer.dart` | CHANGE | Add thousands-comma strip, tashkeel strip |
| `engine/parser/parser_engine.dart` | CHANGE | International parens pattern, fee/totalDue labels, balance labels, 3 new date formats, `بقيمة` label, `الجهة:` merchant, funding-wallet exclusion |
| `engine/categorization/category_seeds.dart` | CHANGE | Add ~20 Egypt/Gulf merchant keywords |
| `engine/dedup/transaction_dedup.dart` | ADD NEW | SHA-256 dedup service |
| `data/db/app_database.dart` | CHANGE | Add `dedup_hashes` table, bump schema to v5 |
| `test/engine/fixtures/bank_sms_golden_fixtures.dart` | CHANGE | Update 5 conflicting fixtures; add `expectedForeignAmount`/`expectedForeignCurrency` to class; add 20 new fixtures |
| `test/engine/fixtures/ignore_fixtures.dart` | ADD NEW | 3 ignore fixtures from spec |
| `test/engine/fixtures/ambiguous_amount_fixtures.dart` | ADD NEW | BSF 3-amount + barq KWD ambiguity cases |
| `test/engine/parser_quality_golden_test.dart` | CHANGE | Import new fixture files, add test groups |

**Files NOT touched:**
- `parse_result.dart` — no changes needed
- `parser_isolate.dart` — no changes needed
- `amount_candidate.dart` — no changes needed
- `categorizer.dart` — no changes needed
- `merchant_category_map.dart` — no changes needed
- All Flutter/Riverpod/UI files — parser is pure Dart, no UI changes

---

## Part 5 — Open Questions (need owner decision before implementation)

1. **Funding wallet field:** When `من:barq` is detected as a funding source (not a merchant), should `ParsedTransaction` expose it as `fundingSource: String?` (new field), or just set `rawMerchant = null` and silently discard it? The field would be informational only and not shown to the user as the "merchant" but could appear in details.

2. **International amount behavior:** Confirm: when a message contains `USD 4.91 (SAR 18.44)`, we store:
   - `amount = 18.44`, `currency = 'SAR'` (the local amount the user actually paid)
   - `foreignAmount = 4.91`, `foreignCurrency = 'USD'` (informational, shown in details)
   Is this correct, or should we store the foreign and let the user configure their base currency?

3. **Date ambiguity for M/D/YYYY vs DD/MM/YYYY:** STC Bank uses BOTH formats in different messages (`3/9/2026` = Sept 3rd AND `09/03/26` = March 9). For a message with `3/9/2026`, the only disambiguation is the bank profile. Should the bank profile carry a `preferredDateOrder: 'mdy' | 'dmy'` field, or do we just leave these ambiguous cases as low-confidence (date not extracted → no confidence penalty, just null date)?

4. **`creditCardPayment` type in UI:** Is this type shown separately in the dashboard ("Card Bill Payment" category), or is it collapsed into `payment`? This affects how `TransactionType.isExpense` should handle it.

5. **Remote merchant dictionary:** The spec says the merchant dictionary should be admin-managed via remote catalog (not hardcoded). This is currently hardcoded in `category_seeds.dart`. Should we move this to Phase 1 (add it to the Supabase catalog tables now) or keep it hardcoded for Phase 1 and migrate later?

---

## Part 6 — Implementation Order for Codex

Once owner approves, delegate to Codex in this exact order (each phase must be reviewed before the next starts):

**Codex Task 1:** Phase 1-A through 1-E (model changes + normalizer + parser fixes)  
→ all existing tests must still pass after this task  
→ the 3 ignore spec samples and BSF 3-amount should now pass (new tests to add)

**Codex Task 2:** Phase 2 (new bank profiles + all 20 new golden fixtures)  
→ 100% golden corpus pass rate required  
→ no changes to any Flutter UI files

**Codex Task 3:** Phase 3 (category seeds expansion + SHA-256 dedup + schema v5)  
→ dedup unit tests required  
→ schema migration must be idempotent (`IF NOT EXISTS`)

**Codex Task 4:** Phase 4 (AI cascade — deferred, not yet)

---

*Ready for owner review. No code has been written or changed based on this plan.*
