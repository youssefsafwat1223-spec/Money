# Mali — SMS Parser Build Spec (Handoff)

**Project:** Mali — Arabic-first, on-device expense tracker
**Scope:** Gulf (GCC) + Egypt. **Build order starts with Saudi Arabia (client market) + Egypt**, then expand to other Gulf states as additional bank profiles.
**Stack:** Flutter + Drift (on-device DB). Parser logic lives in a pure-Dart `parser-core` module with no Flutter dependencies, so it can be reused/tested standalone.
**Status:** Build-ready spec. Derived from real client SMS samples (included verbatim below) + competitor analysis + architecture decisions. This document supersedes informal notes; treat the SMS samples as the source of truth.

> NOTE TO IMPLEMENTER: The Arabic SMS samples in Section 4 are **real** and must be used **verbatim** as golden test fixtures. Do not "clean up", translate, or paraphrase them. Their exact spacing, punctuation, currency placement, and franco-Arabic merchant names are the whole point.

---

## 0. FIRST TASK FOR THE IMPLEMENTER — AUDIT, THEN PLAN (do this before writing any code)

This spec describes the target system. An existing Mali codebase already exists. **Do NOT start changing or writing code yet.** First:

1. **Audit the existing project.** Read the repo structure, the current parser/Drift/Flutter code, and the existing `parser_strategy_report.md`. Identify what already exists vs. what this spec adds.
2. **Map this spec against the current code.** For each part of the system (normalization, ignore filter, bank detection, rule engine per bank, confidence engine, gates, pending queue, dedup, categorization/admin catalog, AI cascade, privacy/sanitization), state clearly: **already exists / partially exists / missing.**
3. **Return a crystal-clear implementation plan — NOT code yet.** The plan must list, file by file and component by component:
   - **What we will CHANGE** (which existing files/functions, and exactly how)
   - **What we will ADD** (new files/modules/classes, with their responsibility)
   - **What we will REMOVE or refactor** (and why)
   - Order of work (phases), dependencies between tasks, and which Section-4 golden tests each step makes pass.
   - Any open questions or assumptions that need the owner's decision.
4. **Wait for owner approval of the plan before implementing.** The plan will be reviewed first. Only after sign-off, implement phase by phase, keeping the golden tests (Section 4) green.

Output of this first task = a written plan (markdown), explicit and unambiguous: literally "in file X we change Y", "we add new file Z that does W". No guessing, no silent rewrites of working code.

---

## 1. Core Principle (the prime directive)

It is always better to send a message to a **pending** review queue than to **auto-save a wrong transaction**. A wrong auto-save destroys user trust; a pending confirmation is minor friction. Every threshold is designed around this asymmetry.

Three exit gates for every message:

| Gate | Condition | UX |
|------|-----------|-----|
| `auto_confirm` | Known bank + rules extracted cleanly + confidence ≥ 0.90 + no ambiguity | Saved silently |
| `pending_confirmation` | Parseable but uncertain (unknown bank, ambiguity, or any AI output) | User reviews with one tap |
| `ignored` | Not a transaction (OTP, promo, scam, balance-only) | No UI |

**Goal:** maximize auto-confirm rate for the supported banks **while keeping silent wrong saves at zero.** Pending is a safety net for the hard cases, not the default.

---

## 2. Market Scope & Competitor Reality (why this matters)

Target: **GCC + Egypt**. Currencies in scope: SAR, AED, KWD, QAR, BHD, OMR, EGP.

**Important:** KWD/BHD/OMR use **3 decimal places** (not 2). The amount parser must handle both 2-decimal and 3-decimal currencies. SAR/AED/QAR/EGP are 2-decimal.

Competitor findings (verified):
- **PennyWise** (strongest open-source competitor, 90+ banks globally) supports only **4 Saudi banks** (Al Rajhi, SNB, Alinma, STC Bank), **1 Egyptian** (CIB), plus a few UAE (Emirates NBD, FAB, ADCB, Mashreq, Liv) and Bank Muscat (Oman). It is **AGPL-licensed** — use as a *learning reference only*, do NOT copy code.
- **Wafeer** (وفير) — Saudi, semi-manual (copy/paste in some flows), does not operate outside KSA.
- **Say** — voice-first + paid/Android-only SMS; requires the user to remember to log.
- **Obba** — MENA, on-device, ~25 banks, uses SHA-256 hashing for dedup.

**Takeaway:** the market is wide open. Nobody covers the Gulf+Egypt retail/wallet space well. Covering ~6-8 banks per key market accurately beats chasing hundreds. Differentiator is **true automation + accuracy + dedup + clean Arabic UX**, NOT bank count.

---

## 3. Target Banks by Priority

Build profiles in this order. Start where we already have real SMS data (Section 4).

### Saudi Arabia 🇸🇦 (start here — client market)
1. Al Rajhi (الراجحي)
2. SNB / AlAhli (الأهلي)
3. Riyad Bank (رياض)
4. Alinma (الإنماء)
5. STC Pay / STC Bank
6. SABB (ساب)
7. Wallets: urpay, barq, D360, SAIB

### Egypt 🇪🇬 (home market, Android-dominant)
1. NBE — National Bank of Egypt (الأهلي المصري)
2. Banque Misr (بنك مصر)
3. CIB
4. QNB Al Ahli
5. Fawry (wallet)
6. InstaPay (instant transfer)
7. ALEXBANK
8. Orange Cash

### Other Gulf (add as profiles after KSA + Egypt are solid)
- UAE: Emirates NBD, FAB, ADCB, Mashreq, Liv
- Kuwait: NBK, KFH, Burgan, Gulf Bank
- Qatar: QNB, Doha Bank, QIB
- Bahrain: AUB, BBK
- Oman: Bank Muscat, NBO, Bank Dhofar

---

## 4. REAL SMS SAMPLES (golden fixtures — verbatim)

These are real messages from the client. Use exactly as written for the first golden test corpus. The sender label (where known) is shown on its own line.

### Egypt

**NBE — National Bank of Egypt (Arabic):**
```
تم خصم 60.00EGP من بطاقة المدفوعة مقدماً رقم 4907 عند FAWRY*SNTRAL NWR ALA يوم 14/03 الساعه 22:29 المتاح 28.14  للمزيد إتصل ب 19623
```
Expected: type=expense, amount=60.00, currency=EGP, card=4907, merchant=`FAWRY*SNTRAL NWR ALA`, balance=28.14 (ignore as amount), date=14/03 (no year — assume current/receive year), source=prepaid card. Signal: `FAWRY*` prefix = Fawry payment. Merchant is franco-Arabic ("Sentral Nour Al…").

**Orange Cash (English):**
```
Your Debit Card **5398 had a Successful transaction of EGP 33.00 @Orange,your available bal. for lost/stolen card call 16607
```
Expected: type=expense, amount=33.00, currency=EGP (currency BEFORE amount), card=5398, merchant=Orange (after `@`).

### Saudi Arabia

**Al Rajhi (Arabic):**  sender = `الراجحي`
```
شراء PoS
عبر:6826;مدى-ابل باي
بـSAR 24
لـSTARBUCKS
؜13/6/26 16:03
```
Expected: type=expense, amount=24, currency=SAR (after `بـ`), merchant=STARBUCKS (after `لـ`), date=13/6/26 16:03. Signal: `مدى` = mada POS.

**D360 bank (English, international):**
```
International Online Purchase
Amount: USD 4.91 (SAR 18.44)
Card: *2948 - VISA (Ecommerce)
Fee: SAR 0.59
At: SNAP INC SNAP SNAP ADS
Country: United States
On: 2026-06-13 12:16
Available Balance: SAR 225.80
```
Expected: type=expense, amount=**18.44 SAR** (use the LOCAL converted amount in parentheses, NOT 4.91 USD, NOT the fee, NOT the balance), merchant=`SNAP INC SNAP SNAP ADS`, card=2948, balance=225.80 (ignore as amount), fee=0.59 (ignore as amount). This is the hardest case: two amounts + fee + balance.

**Riyad bank (Arabic):**
```
شراء إنترنت
بطاقة:6089*;مدى Apple Pay
مبلغ:700.00 SAR
حساب:369940*
من:barq
في:2026-05-21 14:06
```
Expected: type=expense, amount=700.00, currency=SAR (AFTER amount), card=6089. NOTE: `من:barq` here is the funding wallet, **not** a real merchant — do not treat "barq" as the merchant/category.

**urpay (Arabic):**
```
شراء إنترنت
بطاقة:7640; urpay بطاقة; ; Apple Pay
مبلغ:300 SAR
الرسوم/الضريبة:SAR 0.00
من:barq
10-6-2026 14:32
```
Expected: amount=300 (after `مبلغ:`), ignore `الرسوم/الضريبة` (fee/tax). Same shared format as Riyad.

**SNB / AlAhli (English):**  sender = `Snb الاهلي`
```
Online Purchase
Amount 8 SAR
Account *1202
At barq
Mada-Apple pay *5172
on 21/05/26 at 19:11
```
Expected: amount=8 SAR, merchant after `At` (again `barq` = funding source, not true merchant).

**SAIB — Saudi Investment Bank (Arabic, credit card):**  sender = `saib`
```
شراء عبر نقاط البيع
بطاقة: ***1046;ائتمانية
اسم التاجر: EAST BUFFET FOR SECRET ME
مبلغ العملية: 14.00 SAR
الرصيد المتاح: 5.88 SAR
تاريخ العملية : 2026-05-28 09:09:19
```
Expected: amount=14.00 (after `مبلغ العملية:`), balance=5.88 (after `الرصيد المتاح:` — IGNORE as amount), merchant=`EAST BUFFET FOR SECRET ME` (after `اسم التاجر:`), card=1046 credit. Two amounts in one message — must distinguish amount vs balance by label.

**barq (English, international — Kuwait):**
```
POS International Purchase
Visa card: **1056 (Apple Pay)
Amount: 0.1 KWD (1.22 SAR) FX 12.2000
Wallet balance: 201.04
At: CAESARS
Country: Kuwait
2026-06-12 22:16
```
Expected: amount=**1.22 SAR** (local converted, in parentheses), foreign=0.1 KWD, merchant=CAESARS, balance=201.04 (ignore). Note KWD is 3-decimal.

**STC bank (English, transfer):**
```
Internal outward transfer
Amount:21.00SAR
To:ABDELRAHMAN ABDALLA
Acc:3583*
At:19/04/26 11:07
```
Expected: type=transfer (outward), amount=21.00 (currency `SAR` glued, no space), beneficiary=`ABDELRAHMAN ABDALLA` (after `To:`).

**ANB — Arab National Bank — ATM DEPOSIT (Arabic, income type):**  sender = `anb`
```
إيداع ATM
بـ:SAR 4000.00
الحساب:0017
بطاقة، مدى،1922
في:26-06-15 10:47
```
Expected: type=**income/deposit**, amount=4000.00, currency=SAR (before, after `بـ:`), account=0017. ⚠️ Date `26-06-15` is **YY-MM-DD** (year first). Trigger words: `إيداع`.

**ANB — GOVERNMENT PAYMENT (Arabic, traffic fines):**  sender = `anb`
```
مدفوعات وزارة الداخلية
من:0017
بـ:SAR 113
الجهة:المخالفات المرورية
الخدمة:سداد مخالفات مرورية-رقم المخالفة
رقم مرجعي:6824106852
في:26-06-15 10:49
```
Expected: type=expense (government/bill payment), amount=113, payee=`المخالفات المرورية` (after `الجهة:`), ref=6824106852. Trigger words: `مدفوعات`, `سداد`.

**BSF — Banque Saudi Fransi (Arabic, credit card POS — THREE amounts):**  sender = `BSF`
```
شراء عبر نقاط البيع بـ SAR 150.00
رسوم العملية:0.00
من Al-Rajul Al-Amthal for Me
بطاقة ائتمانية 9221* من خلال Apple Pay
المبلغ الإجمالي المستحق SAR 5620.87
الرصيد المتوفر: SAR 14379.13
في 26-06-14 20:12
```
Expected: type=expense, amount=**150.00** (after `بـ`), fee=0.00 (`رسوم العملية:` ignore), merchant=`Al-Rajul Al-Amthal for Me` (after `من`, franco for "الرجل الأمثل"), card=9221 credit. ⚠️ IGNORE both `المبلغ الإجمالي المستحق` (total due 5620.87) and `الرصيد المتوفر` (balance 14379.13). THREE amounts in one message — label discrimination is critical.

**STC bank — ADD FUNDS (Arabic, income):**
```
إضافة أموال لحسابك
بـ:300.56 ر.س
عبر:*XXXX
في:3/9/2026 11:17 PM
```
Expected: type=income, amount=300.56, currency=`ر.س`→SAR. ⚠️ Date `3/9/2026` here is **M/D/YYYY**.

**STC bank — OUTWARD TRANSFER (Arabic):**
```
حوالة داخلية صادرة
بـ:300.56ر.س
إلى:SARRAA ALASMARI
حساب:5438*
في:09/03/26 23:23
```
Expected: type=transfer, amount=300.56 (currency `ر.س` glued), beneficiary=`SARRAA ALASMARI` (after `إلى:`). ⚠️ Date `09/03/26` is **DD/MM/YY** — note STC uses BOTH M/D/YYYY and DD/MM/YY in different messages.

**STC bank — INTERNATIONAL PURCHASE (Arabic):**
```
عملية انترنت
بـ:USD 248.95
من:ALIEXP
بطاقة:*7238
في:16/04/26 10:48
```
Expected: type=expense, foreign amount=USD 248.95 (no local conversion shown here), merchant=`ALIEXP` (AliExpress), card=7238.

**Albilad (Arabic, POS):**  sender = `البلاد`
```
مشتريات نقاط البيع
بطاقة: **1519; مدى, Apple PAY
مبلغ: 7.00 SAR
لدى: BOOFAYAH NJOOD
في: 2023-10-22 07:24
```
Expected: amount=7.00 (after `مبلغ:`), merchant=`BOOFAYAH NJOOD` (after `لدى:`), card=1519, signal=mada.

**Bank Aljazira (Arabic, e-commerce):**  sender = `هذا الجزيرة`
```
معاملة التجارة الإلكترونية عبر مدى - الشراء عبر الإنترنت (Apple Pay)
بقيمة 143.80 SAR
من:6001
لدى Ninja
بطاقة مدى 8277
في 2026-06-13 19:19
```
Expected: amount=143.80 (after `بقيمة` — NEW amount label), merchant=`Ninja` (after `لدى`), card=8277, signal=mada.

**Emirates/Dubai Bank (Arabic, credit card payment confirmation):**  sender = `بنك دبي`
```
بطاقة إئتمانية: تأكيد السداد
بطاقة: XX2678;إئتمانية
مبلغ: 250.93  SAR
رصيد: 18,000.00 SAR
في: 24-01-2025
```
Expected: type=credit-card-payment, amount=250.93 (after `مبلغ:`), balance=18,000.00 (after `رصيد:` IGNORE). ⚠️ Balance has a **thousands comma** (`18,000.00`) — strip commas before parsing. Date `24-01-2025` = DD-MM-YYYY.

### IGNORE samples (real — must be filtered out, NOT parsed as transactions)
```
عزيزي عميل anb، تم تجميد حسابك لعدم تحديث بياناتك البنكية. يمكنك تحديث بياناتك من خلال تطبيق anb أو زيارة أقرب فرع
```
```
لحمايتك تم تسجيل خروج أحد أجهزتك من القنوات الرقمية، بسبب تسجيل دخول أكثر من جهاز
```
```
Dear Customer, We would like to inform you that Your Complaint (Reference 0011389642) has been Closed...
```
Expected for all three: **ignored** (account-admin / security / complaint notices — no money moved). The account-freeze message also resembles phishing; treat administrative/security notices as ignore.

> MISSING DATA TO REQUEST FROM CLIENT: exact **Sender IDs** for each bank (the label shown above the SMS), plus remaining message types per bank: **salary/deposit, ATM cash withdrawal, refund, wallet top-up, declined/failed.** Also need real Egyptian samples for Banque Misr, CIB, QNB.

### Banks now covered by real samples (15 senders)
Egypt: NBE, Orange. Saudi: Al Rajhi, D360, Riyad, urpay, SNB, SAIB, barq, STC Bank, **ANB, BSF, Albilad, Bank Aljazira**. UAE: **Emirates/Dubai Bank**.
(Today's batch added 6 senders — ANB, BSF, Albilad, Bank Aljazira, Emirates/Dubai Bank, plus new message types for the already-known STC Bank.)

---

## 5. Patterns Learned From Real Data (critical for the amount parser)

1. **Currency appears BEFORE, AFTER, and GLUED to the amount.** All must be handled:
   - Before: `EGP 33.00`, `بـSAR 24`, `USD 4.91`, `بـ:SAR 4000.00`
   - After: `700.00 SAR`, `8 SAR`, `143.80 SAR`
   - Glued (no space): `60.00EGP`, `21.00SAR`, `300.56ر.س`
2. **Distinguish amount vs balance vs fee vs total-due by LABEL, never by position.** A single message can contain up to **THREE** amounts (see BSF). Take only the transaction amount:
   - Amount labels: `مبلغ:`, `مبلغ العملية:`, `بقيمة`, `بـ`, `بـ:`, `تم خصم`, `Amount:`, `Amount`
   - Balance labels (IGNORE): `الرصيد المتاح:`, `الرصيد المتوفر:`, `رصيد:`, `المتاح`, `Available Balance:`, `Wallet balance:`
   - Fee labels (IGNORE): `الرسوم/الضريبة:`, `رسوم العملية:`, `Fee:`
   - Total-due labels (IGNORE): `المبلغ الإجمالي المستحق`
3. **International transactions.** Format `FOREIGN (LOCAL)` e.g. `USD 4.91 (SAR 18.44)` → take the **local** amount in parentheses. But some banks show only the foreign amount with no conversion (STC `بـ:USD 248.95 من:ALIEXP`) → keep foreign amount + currency, flag for conversion/pending.
4. **Funding-wallet ≠ merchant.** `من:barq` / `At barq` is the payment source, not the merchant.
5. **Franco-Arabic merchants** are common (`SNTRAL NWR ALA`, `Al-Rajul Al-Amthal for Me`, `BOOFAYAH NJOOD`). Categorization must tolerate Arabic-written-in-Latin.
6. **Thousands separators:** balances/amounts may contain commas (`18,000.00`, `14379.13`). Strip `,` (and Arabic `٬`) before numeric parse.
7. **Multiple transaction TYPES — detect type first, then apply type-specific extraction:**
   - Expense/POS: `شراء`, `مشتريات نقاط البيع`, `شراء عبر نقاط البيع`, `عملية انترنت`, `Purchase`, `تم خصم`
   - Income/deposit: `إيداع`, `إيداع ATM`, `إضافة أموال`, `credited`, `deposit`
   - Transfer: `حوالة`, `حوالة داخلية صادرة`, `تحويل`, `transfer`, `إلى:`/`To:` (outward)
   - Credit-card payment: `تأكيد السداد`, `بطاقة إئتمانية`
   - Government/bill payment: `مدفوعات`, `سداد`, `الجهة:`
8. **DATE FORMATS ARE INCONSISTENT — even within the SAME bank.** Build a tolerant multi-format date parser. Observed: `YYYY-MM-DD` (Aljazira, SAIB), `YY-MM-DD` (ANB `26-06-15`), `DD/MM/YY` (STC `09/03/26`), `M/D/YYYY` (STC `3/9/2026`), `DD-MM-YYYY` (Dubai `24-01-2025`), `DD/MM/YY HH:MM` (Al Rajhi), and year-less (`يوم 14/03`, NBE → fall back to received-timestamp year). When ambiguous (e.g. `3/9` vs `9/3`), prefer the bank's known format from its profile; otherwise flag low confidence.
9. **Merchant/beneficiary labels:** merchant after `لدى:`/`لدى`/`من`/`At`/`@`/`اسم التاجر:`; beneficiary after `إلى:`/`To:`.
10. **Signals:** `مدى`/`mada` = Saudi POS; `FAWRY*`/`Meeza` = Egypt payment rails.
11. **Administrative/security/complaint notices must be IGNORED** (account freeze, device logout, complaint closed) — see Section 4 ignore samples. They move no money and some resemble phishing.

### Shared formats (reduces work — use base parsers)
- Riyad ≈ urpay use nearly identical Arabic format (`شراء إنترنت` + `بطاقة:` + `مبلغ:` + `من:`).
- Albilad + Aljazira + SAIB share the `... نقاط البيع/الشراء ... مبلغ:/بقيمة ... لدى: ...` mada-POS Arabic family.
- ANB + BSF use `بـ:SAR ...` (currency-before) Arabic family.
- Build a **`BaseSaudiParser`** for the common mada-POS pattern; banks inherit and override specifics. Build a **`BaseEgyptParser`** for `تم خصم … عند … المتاح`.
- This mirrors PennyWise's proven `UAEBankParser` / `BaseIndianBankParser` base-class approach.

---

## 6. Architecture — 7-Layer Pipeline (all on-device for layers 1–5)

```
Raw SMS
  → 1. Normalization
  → 2. Ignore Filter   (if ignored → exit, no UI)
  → 3. Bank/Sender Detection
  → 4. Bank-Specific Rule Engine   (matched profile)  ─┐
        or Generic Heuristic Parser (no match, conf capped 0.79)
  → 5. (optional) AI Fallback   → always pending
  → 6. Confidence Engine (final gate)
  → 7. Categorization
Output: ParseResult { transaction, confidence, gate }
```

### 6.1 Normalization
- Eastern→Western digits (٣٥→35), strip tashkeel, normalize hamza variants for matching, collapse whitespace.
- Normalize currency aliases → ISO: `ر.س / ريال / SR → SAR`; `ج.م / جنيه → EGP`; etc.
- Keep original text alongside normalized form (for display + grounding checks).
- Must be idempotent, fast, language-agnostic.

### 6.2 Ignore Filter (over-inclusive on OTP)
Ignore if: OTP/2FA (`رمز التحقق`, `كود التحقق`, `OTP`, `do not share`, `لا تشاركه`), promo (`عرض`, `مبروك`, `اربح`, prize), phishing (links, `اضغط`, `verify`), balance-only inquiry, statement-ready. Also run OTP check against the **raw** (pre-normalized) text.
**Note from real data:** Al Rajhi sends multiple OTP types (app-login OTP, mada card-add OTP) that must all be ignored — only debit/credit/transfer notifications are transactions.

### 6.3 Bank/Sender Detection
- Primary: exact/normalized Sender-ID match against bank profile (e.g. `AlRajhi`, `RAJHI`, `الراجحي`).
- Fallback: body keyword scan.
- BankProfile schema must include: `bankKey, displayName, country, locale, senderIds[], keywords[], currencyAliases, currencyDecimals, ignoreRules[], typeRules{}, amountRules[], balanceRules[], feeRules[], merchantRules[], dateRules[], version, source`.
- Profiles bundled in-app + remote catalog override via sync (remote wins if version higher).

### 6.4 Rule Engine (matched bank) — deterministic
Extract type/amount/currency/merchant/balance/card/date using the bank's labels. Aggressive when sender matched. **This is the primary path and must handle the Section 4 samples with confidence ≥ 0.90.**

### 6.5 Generic Heuristic Parser (unknown bank)
Conservative. **Confidence hard-capped at 0.79** → unknown banks can never auto-confirm. Needs both a currency token AND a transaction keyword to score an amount candidate.

### 6.6 AI Fallback (optional, opt-in) — always pending
See Section 7.

### 6.7 Confidence Engine & Gates
- Inputs (weighted): sender matched, amount extracted, no amount ambiguity, type identified, currency explicit, merchant extracted, date extracted. Penalize amount ambiguity (two competing candidates). Generic path capped 0.79; AI path capped 0.69.
- Gates: `≥0.90 → auto_confirm`, `0.70–0.89 → pending`, `<0.70 → ignored (insufficient signal)`.
- **auto_confirm requires ALL of:** sender-ID matched (not just keywords) AND type ≠ unknown AND exactly one strong amount candidate AND explicit currency AND score ≥ 0.90. Any failure → pending.

---

## 7. AI Strategy (rules for the numbers, AI for the fuzzy)

**Hard rule:** AI never extracts the authoritative amount, never runs on every message, and its output is **always pending** (never auto-saves) because it is non-deterministic and the domain is money.

Where AI is used:
1. **Categorization of unknown merchants** (e.g. `EAST BUFFET`, `SNTRAL NWR ALA`) — only when the dictionary + keyword rules miss.
2. **Fallback for unsupported banks** — banks outside the profile list whose generic parse failed. Output → pending.
3. **Admin "Parser Lab"** — AI drafts new bank regex from example messages at *development* time (intelligence used once, not per-user).

### 7.1 Grounding / validation (the client's idea — implement this)
When AI extracts a number, **verify the exact number string exists in the original message** before accepting it. If the AI's amount is not literally present in the source text → reject as hallucination. Optionally run rules + AI and compare:
- Agree → high confidence.
- Disagree → pending.
- AI number absent from source → reject.

This protects against hallucination on unsupported banks specifically.

### 7.2 Cascade (how on-device + cloud AI fit together)
```
Rules (on-device)         → conf ≥ 0.90? auto_confirm. (free, instant, private)
  ↓ fail / low conf
[optional] Qwen on-device → result → pending. (free, private, slower)
  ↓ fail / unsure
[optional] Gemini API     → grounded result → pending. (opt-in + sanitized only)
```
Build incrementally: **v1 = rules only. v2 = + Gemini API for gaps. v3 = + Qwen on-device (only if full privacy demanded).** Add Gemini first (just an API call); add on-device Qwen later (heavier — ~1–2GB model, device load).

### 7.3 Model choice
- **Cloud (cheap + excellent Arabic): Gemini Flash.** Currently among the top-ranked models for Arabic *and* among the cheapest; generous free tier. Best fit for this project's small AI usage (gaps only → ~<$1/month).
- **On-device (full privacy): Qwen** (open-weight, strong Arabic, runs on phone via MediaPipe — same family PennyWise uses).
- Use Gemini Flash by default; switch to on-device Qwen only if the client demands messages never leave the device.

---

## 8. Categorization (separate layer, after parsing) — ADMIN-MANAGED DYNAMIC DICTIONARY

The merchant→category dictionary is **NOT hardcoded**. It is a **server-managed catalog** edited from the Admin Panel and synced to devices (same mechanism as the remote bank-rule catalog). This lets the dictionary grow over time without app updates.

**Resolution order on device:**
1. **Central merchant dictionary** (synced from Admin Panel): `STARBUCKS→cafes`, `EAST BUFFET→restaurants`, `SNAP→digital/subscriptions`, `Orange→telecom`, `CAESARS→entertainment`. Seed with top KSA + Egypt merchants (restaurants/cafes, supermarkets — بنده/العثيم/كارفور/Spinneys, delivery — HungerStation/جاهز/Talabat/Mrsool, subscriptions — Netflix/Spotify/Shahid/OSN, fuel — Aramco/ساسكو).
2. **Keyword fallback**: `CAFE/COFFEE/كوفي/قهوة→cafes`, `RESTAURANT/مطعم/BUFFET→restaurants`, `PHARMACY/صيدلية→health`, `STATION/محطة→fuel`.
3. **User correction → learned rule** (local `RuleEngine`): remember the user's choice; auto-apply next time for the same merchant on that device.
4. **AI** only for fuzzy/franco merchants the above miss (e.g. `SNTRAL NWR ALA`).

### 8.1 Unknown-merchant feedback loop (Admin Panel)
When a merchant is not in the central dictionary:
- Device tags it "uncategorized" (or shows AI's guess) and **sends ONLY the merchant string** to the Admin Panel — anonymized.
- Admin reviews the queue of unknown merchants, assigns a category once (e.g. `SNTRAL NWR ALA → bills/services`), saves to the central catalog.
- On next sync, all devices pull the update; that merchant auto-categorizes everywhere thereafter.
- Admin can also add/edit/bulk-import dictionary entries directly (e.g. when a new merchant launches in the market).

```
Device:  merchant "X" not in local dict
         → tag uncategorized (or AI guess)
         → POST merchant name only  [anonymized]  → Admin
Admin:   review unknown-merchant queue → set "X = restaurants" → save to central catalog
Devices: on sync → pull update → "X" auto-categorizes from now on
```

### 8.2 PRIVACY — what may be sent to the Admin Panel
- ✅ Allowed: the **merchant string only** (e.g. `SNTRAL NWR ALA`). This does not identify the user.
- ❌ Never sent: amount, balance, card number, account number, user identity, full SMS text, timestamps tied to a user.
- The unknown-merchant report must be a single anonymized field. This keeps the privacy promise (Section 9) intact while growing the dictionary via crowdsourced-but-anonymized signals.

### 8.3 Guard
A funding wallet (`barq`) is a payment source, not a merchant — exclude it from categorization and from the unknown-merchant report.

---

## 9. Privacy (the core promise — esp. KSA/Gulf)

- Raw SMS **never leaves the device** by default. Parsing (rules) + on-device AI keep everything local.
- Cloud AI (Gemini) is **opt-in only** and the text is **sanitized first** (strip card numbers, account numbers, names, phone numbers) before transmission.
- Pending queue stores raw SMS only until the item is resolved (confirmed/dismissed), then deletes it. Never permanently stored.
- No raw SMS in logs, crash reports, or analytics.
- This privacy stance is the main trust differentiator vs competitors.

---

## 10. Dedup (must-have — competitor Obba has it, we don't yet)

One real transaction can arrive as multiple SMS (bank + wallet + card notification). Implement **content-hash dedup** (e.g. SHA-256 over normalized {amount, currency, merchant, date-rounded, card-last4}). Drop duplicates within a short time window. Also keep a manual "already logged" dismissal.

---

## 11. Implementation Plan (ordered)

**Phase 1 — Foundation (start now):**
1. `parser-core` Dart module (no Flutter deps) with `BankParser` base, `BaseSaudiParser`, `BaseEgyptParser`, `BankParserFactory` (sender → parser).
2. Normalization layer + unit tests (every currency alias, numeral conversion, glued-currency case, 2- vs 3-decimal).
3. Ignore filter + tests (one per category; include false-ignore prevention; cover Al Rajhi's multiple OTP types).
4. Confidence engine + gate logic.

**Phase 2 — First parsers (we have real data):**
5. Al Rajhi, Riyad, urpay, SNB, SAIB, STC (KSA) + NBE, Orange (Egypt) — built from Section 4 samples.
6. Golden test corpus from the Section 4 messages (exact strings). Target 100% pass.

**Phase 3 — Categorization, dedup, safety:**
7. Merchant dictionary (KSA + Egypt) + keyword fallback + learned-rule engine.
8. SHA-256 dedup.
9. Pending queue (Drift) + home-screen pending card + correction logging.

**Phase 4 — AI + expansion:**
10. Gemini Flash fallback (opt-in, sanitized, grounded, always pending) for unsupported banks + fuzzy categorization.
11. Add remaining Egypt banks (Banque Misr, CIB, QNB, Fawry, InstaPay) from new real samples.
12. Add other Gulf states (UAE, Kuwait, Qatar, Bahrain, Oman) as profiles. Mind 3-decimal currencies (KWD/BHD/OMR).
13. Admin Parser Lab (paste SMS → see parse → AI drafts rule).
14. (Optional) Qwen on-device if full privacy required.

---

## 12. Worked Example (end-to-end, both paths)

**Known bank (Al Rajhi sample):**
Normalize → not ignored (`شراء`) → sender `الراجحي` matched → rules extract: type=expense, amount=24, currency=SAR (after `بـ`), merchant=STARBUCKS (after `لـ`), signal=mada → confidence ≈0.95 → **AUTO_CONFIRM** (no AI) → categorize STARBUCKS=cafes via dictionary.

**Unknown bank (`عميلنا العزيز، عملية بـ 350 ريال في متجر النور`):**
Normalize → not ignored → sender not matched → generic parser amount=350, conf capped 0.79 → (if enabled) AI fallback → **grounding check: is "350" literally in the text? yes** → accept → confidence <0.90 → **PENDING** → categorize "متجر النور" via AI → user confirms with one tap.

---

## 13. What's Still Needed From the Client

1. **Sender IDs** for every target bank (the label above each SMS).
2. **More message types** per bank: salary/deposit (income), ATM withdrawal, refund, wallet top-up, declined/failed.
3. **Egypt samples** for Banque Misr, CIB, QNB Al Ahli, Fawry, InstaPay.
4. Confirmation of platform priority per market (Android-first for Egypt; iOS is high in Gulf → iOS requires the Shortcuts/Transaction-automation path since iOS cannot read the SMS inbox directly — design this separately).

---

## 14. License / IP Note

PennyWise (the main open-source reference) is **AGPL v3**. Study its architecture and pattern *logic* freely, but **write all Mali code from scratch** — do not copy its source, or Mali would be forced open under AGPL. Logic/ideas are fine; verbatim code is not.
