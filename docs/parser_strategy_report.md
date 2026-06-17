# Mali Parser Strategy Report

**Topic:** Building a Professional, Production-Grade Bank SMS Parser  
**App:** Mali — Arabic-first on-device expense tracker  
**Date:** June 2026  
**Status:** Strategic reference document — no code changes

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Why a Perfect Universal Parser Is Impossible](#2-why-a-perfect-universal-parser-is-impossible)
3. [The Core Safety Principle](#3-the-core-safety-principle)
4. [Recommended Parser Architecture](#4-recommended-parser-architecture)
5. [Where Parsing Should Happen](#5-where-parsing-should-happen)
6. [Exact Decision Flow](#6-exact-decision-flow)
7. [AI Usage Strategy](#7-ai-usage-strategy)
8. [Dataset Strategy](#8-dataset-strategy)
9. [Golden Tests](#9-golden-tests)
10. [Parser Lab in the Admin Panel](#10-parser-lab-in-the-admin-panel)
11. [Confidence Scoring](#11-confidence-scoring)
12. [Categorization Strategy](#12-categorization-strategy)
13. [Privacy and Security](#13-privacy-and-security)
14. [Multi-Country and Multi-Bank Scaling](#14-multi-country-and-multi-bank-scaling)
15. [MVP Plan](#15-mvp-plan)
16. [6-Month Roadmap](#16-6-month-roadmap)
17. [Success Metrics](#17-success-metrics)
18. [Architecture Diagram](#18-architecture-diagram)
19. [Actionable Next Steps for Mali](#19-actionable-next-steps-for-mali)

---

## 1. Executive Summary

Mali's core value proposition rests on one claim: **it automatically knows where your money went.** That claim lives or dies with the quality of the SMS parser.

The parser must do something deceptively hard: take a single unstructured text message — written in Arabic, English, or a mix of both, by a different bank every time, with no consistent format, possibly containing noise, scam text, or OTP codes — and produce a structured financial record with a `±0` error rate on the amount field.

The right architecture is not a single clever algorithm. It is a **layered safety system** that combines:

- Fast, deterministic, bank-specific rules (the primary path)
- A generic heuristic fallback (secondary path)
- An optional AI server fallback (tertiary path, never auto-saves)
- A human confirmation queue (safety net for everything uncertain)
- A continuous feedback loop that improves rules over time

**The prime directive:** it is always better to send a message to the pending queue than to auto-save a wrong transaction. A wrong auto-save destroys user trust. A pending confirmation is a minor friction. Design every threshold and gate with this asymmetry in mind.

---

## 2. Why a Perfect Universal Parser Is Impossible

Understanding the limits of the problem is a prerequisite to building the right system. These limits are permanent — they cannot be engineered away.

### 2.1 Format Diversity Is Unbounded

There are thousands of banks and fintech apps across the Arabic-speaking world. Each one:

- Chooses its own SMS template
- Changes templates without notice (branding updates, regulatory changes)
- May send different templates for different transaction types (POS vs. online vs. ATM vs. transfer)
- May mix Arabic and Latin characters differently
- May abbreviate currency names differently (SAR / ر.س / ريال / SR)
- May omit fields (no merchant name for some ATM withdrawals, no balance for some purchases)

A parser that is "complete" today is already incomplete tomorrow because a bank updated its template.

### 2.2 Ambiguity Is Inherent

A single SMS may contain:
- Multiple numbers (amount, balance, card last4, reference number, phone number, date parts)
- No explicit label for which number is the amount
- A merchant name that looks like a city, person name, or product name
- A date in an ambiguous format (03/04 — is it March 4 or April 3?)
- Currency implied but not stated

No algorithm can resolve all of these deterministically.

### 2.3 Adversarial Content Is Common

SMS inboxes contain:
- OTP and 2FA codes (must never be parsed as transactions)
- Promotional messages (may contain amounts in currency-like format)
- Scam/phishing messages (may perfectly mimic bank SMS format)
- Balance inquiry replies (an amount, but not a transaction)
- Failed/declined transaction notifications (not an expense)
- Informational messages ("your statement is ready")

### 2.4 Language and Script Complexity

Arabic SMS:
- Uses Eastern Arabic numerals (٠١٢٣٤٥٦٧٨٩) or Western (0-9) or both
- Uses Tashkeel (diacritics) or not
- Mixes hamza variants (أ / إ / ا) inconsistently
- Uses different date formats (هجري / ميلادي, DD/MM/YYYY, YYYY-MM-DD)
- Contains currency aliases that differ by country and bank

### 2.5 The Long Tail Problem

Even if you cover the top 20 banks in Saudi Arabia and Egypt perfectly (which is achievable), the remaining thousands of smaller banks, wallets, fintech apps, and merchant payment notification services will always produce messages the parser has never seen.

**Conclusion:** Design for high precision on covered banks, graceful degradation for uncovered banks, and a human-in-the-loop for everything else.

---

## 3. The Core Safety Principle

Every parsed message must exit through exactly one of three gates:

| Gate | Name | Condition | User Experience |
|------|------|-----------|-----------------|
| ✅ | `auto_confirm` | Extremely high confidence, bank-specific rule matched | Transaction saved silently |
| ⏳ | `pending_confirmation` | Parseable but uncertain | User sees a card to review and confirm |
| 🚫 | `ignored` | Not a financial transaction | No UI shown |

### 3.1 The Auto-Confirm Threshold

Auto-confirm means **no human ever reviews this transaction before it is saved.** The bar must be very high.

Criteria for auto-confirm (all must be true):
1. Sender ID matched a known, trusted bank profile
2. Transaction type identified with certainty (payment/withdrawal/income/transfer/refund)
3. Amount extracted without ambiguity (only one plausible transaction amount in the message)
4. Currency resolved explicitly from the message text
5. Combined confidence score ≥ 0.90 (not a soft threshold — hard gate)

The moment any of these five conditions fails, the message falls to `pending_confirmation`. Never loosen this gate to increase auto-save rate. Increase it only by improving rule quality.

### 3.2 Pending Confirmation

Pending messages are parsed to the best ability of the parser and presented to the user for one-tap confirmation. The user can:
- Confirm the parsed fields (optionally editing amount, merchant, category, type)
- Dismiss (mark as not a transaction)
- Report (flag as a parse error)

Pending is not a failure state. It is the correct output for ambiguous inputs.

### 3.3 Ignored Messages

Messages that match ignore patterns never reach the UI. The ignore list is conservative — when in doubt, do not ignore. Ignoring a real transaction is worse than surfacing an OTP as pending.

**Ignore conditions:**
- Contains OTP/2FA/verification code keywords
- Contains promotional language (offer, coupon, prize, win)
- Contains phishing indicators (links, "click here", "verify your account")
- Is a balance inquiry reply with no transaction context
- Is a statement-ready notification
- Sender is a known non-transaction sender (marketing shortcodes)

---

## 4. Recommended Parser Architecture

The parser is a layered pipeline. Each layer processes the output of the previous one. A message exits at the earliest layer that can classify it with sufficient confidence.

```
Raw SMS
  │
  ▼
Layer 1: Normalization
  │
  ▼
Layer 2: Ignore Filter
  │  (if ignored → exit)
  ▼
Layer 3: Sender / Bank Detection
  │
  ▼
Layer 4: Bank-Specific Rule Engine
  │  (high confidence → auto_confirm)
  │  (low confidence → continue)
  ▼
Layer 5: Generic Heuristic Parser
  │  (medium confidence → pending_confirmation)
  │  (low confidence → continue)
  ▼
Layer 6: AI Server Fallback (optional)
  │  (result → always pending_confirmation, never auto_confirm)
  ▼
Layer 7: Confidence Engine (final gate)
  │
  ▼
Output: ParseResult { transaction, confidence, gate }
```

### 4.1 Normalization Layer

Transforms raw input into a canonical form before any rule is applied. Must be idempotent and fast (runs on-device, synchronously).

**Responsibilities:**
- Convert Eastern Arabic numerals to Western (٣٥ → 35)
- Normalize Arabic character variants (أإآ → ا, ة → ه for matching purposes)
- Strip Tashkeel (diacritics)
- Normalize whitespace (tabs, non-breaking spaces, multiple spaces → single space)
- Normalize currency aliases (ر.س / ريال سعودي / SR → SAR, ج.م / جنيه → EGP)
- Normalize date separators (٢٠٢٦/٠٣/١٤ → 2026/03/14)
- Lowercase Latin characters
- Preserve original text alongside normalized form (for display)

**What normalization must NOT do:**
- Remove words or restructure sentences
- Interpret meaning
- Be language-specific (it must handle Arabic, English, and mixed text uniformly)

### 4.2 Ignore Filter

Runs after normalization. A fast keyword scan against a curated deny-list. This is the first safety gate and must be **over-inclusive** — when a keyword pattern could match either an OTP or a real transaction, treat it as an OTP.

**Ignore pattern categories:**

| Category | Example Keywords |
|----------|-----------------|
| OTP / 2FA | otp, رمز التحقق, رمز الدخول, كود التحقق, لا تشاركه, do not share |
| Promotional | عرض خاص, promo, coupon, prize, winner, مبروك, اربح |
| Phishing | http://, https://, اضغط, click here, verify your account |
| Balance inquiry | رصيدك الحالي (without transaction context), your balance is |
| Statement | كشف حساب, statement ready, account summary |
| Marketing shortcodes | (sender-based filtering, not content-based) |

**Important:** The ignore filter should also run against the raw (pre-normalized) text for OTP detection, because normalization might change keyword forms.

### 4.3 Bank / Sender Detection

Attempts to identify which bank or wallet sent this message. Two sources of signal:

1. **Sender ID** (most reliable): The SMS sender field. In most countries, banks register short alphanumeric sender IDs with telecom operators (e.g., "CIB", "SNB", "RAJHI", "STC-Pay"). If the sender ID exactly matches a known profile, this is high-confidence bank identification.

2. **Body keywords** (fallback): If the sender ID is unknown or a local phone number, scan the message body for bank-identifying phrases (bank name, logo text, contact numbers, known URL patterns). This is lower confidence.

**Bank profile structure:**

```
BankProfile {
  bankKey: string           // stable internal ID, never changes
  displayName: string       // shown in UI
  country: string           // ISO 3166-1 alpha-2
  locale: string            // ar-SA, ar-EG, etc.
  senderIds: string[]       // exact sender ID matches
  keywords: string[]        // body keyword fallback matches
  currencyAliases: map      // bank-specific currency string → ISO code
  ignoreRules: string[]     // bank-specific additional ignore patterns
  typeRules: map            // TransactionType → trigger phrases
  amountRules: string[]     // labels that precede the transaction amount
  balanceRules: string[]    // labels that precede the balance
  merchantRules: string[]   // prepositions/labels that precede the merchant
  dateRules: string[]       // date context words
  version: int              // incremented on any rule change
  source: TransactionSource // bank / card / wallet
}
```

Bank profiles are the **primary accuracy driver.** A message parsed with a matched bank profile should consistently score above the auto-confirm threshold. A message parsed without a matched bank profile should rarely auto-confirm.

**Profile storage:**
- Bundled in the app (fast, offline, version-controlled)
- Remote catalog supplements and overrides bundled profiles (via Supabase)
- Remote profiles are fetched on sync, validated, and stored in Drift
- App merges remote + bundled at parse time, remote takes priority if version is higher

### 4.4 Bank-Specific Rule Engine

Given a matched bank profile, applies the bank's rules to extract:

| Field | Extraction Method |
|-------|-------------------|
| Transaction type | keyword list from `typeRules` |
| Amount | `amountRules` label proximity + currency adjacency |
| Currency | explicit currency token or `currencyAliases` map |
| Merchant | `merchantRules` preposition search + cleanup |
| Balance | `balanceRules` label proximity |
| Card last4 | pattern match (stars, "رقم", "ending", card context) |
| Date/time | ISO-8601, DD/MM/YYYY, DD/MM, contextual time |

When a bank profile is matched, the rule engine can be aggressive: it trusts the sender and applies bank-specific patterns without needing generic fallbacks.

### 4.5 Generic Heuristic Parser

Runs when no bank profile is matched. Much more conservative.

**Key differences from bank-specific parsing:**

- Confidence cap: never exceeds `genericMaxConfidence` (currently 0.79), which is below the `auto_confirm` threshold (0.90). **This means a message parsed by the generic parser can never auto-confirm.**
- More cautious amount candidate scoring (needs both a currency token AND a transaction keyword to score high)
- No merchant extraction unless a known preposition is present
- No card last4 extraction unless stars or explicit "ending" pattern present

This cap is the most important safety property of the generic parser. It guarantees that unknown banks never silently save transactions.

### 4.6 AI Server Fallback

An optional third layer that calls a server-side AI (Claude or similar) when:
- The message was not ignored
- A real transaction seems likely (at least one numeric amount, at least one transaction keyword)
- Neither the bank-specific nor generic parser produced a result above the `pending_confirmation` minimum threshold

**AI fallback output is always `pending_confirmation`.** No exceptions. The AI output feeds into the same confidence engine as the heuristic parser, but the final gate is hardcoded to `pending` regardless of the AI's expressed confidence. The AI helps the user review, not auto-save.

See Section 7 for the full AI strategy.

### 4.7 Confidence Engine

Aggregates signals from all previous layers into a single score in [0, 1].

Inputs:

| Signal | Weight |
|--------|--------|
| Bank profile matched | +0.15 |
| Sender ID matched (vs. keyword match) | +0.10 |
| Amount extracted | +0.25 |
| No amount ambiguity (only one strong candidate) | +0.10 |
| Transaction type identified | +0.15 |
| Currency resolved explicitly | +0.10 |
| Merchant extracted | +0.10 |
| Date extracted | +0.05 |
| Amount ambiguity (two competing candidates) | −0.25 |
| Generic parser path (no bank match) | capped at 0.79 |
| AI fallback path | capped at 0.69 (always pending) |

**Thresholds:**

| Range | Gate |
|-------|------|
| ≥ 0.90 | `auto_confirm` |
| 0.70 – 0.89 | `pending_confirmation` |
| < 0.70 | `ignored` (not enough signal to show) |

### 4.8 Pending Confirmation Queue

The pending queue is a Drift table (`pending_transactions`) that holds:
- The raw SMS text (temporarily, until confirmed or dismissed)
- The best-effort parsed fields
- The confidence score
- The matched bank key (if any)
- The received-at timestamp
- A flag for user correction report submission

**UI treatment:**
- Pending transactions appear as a dismissible card in the home screen and notification
- Confirming pre-fills the transaction form with parsed fields for easy one-tap save
- User can edit any field before confirming
- Dismissal options: "not a transaction", "already logged", "report parse error"

**Retention:** Raw SMS text in the pending queue is deleted when the pending item is resolved (confirmed, dismissed). It is never permanently stored.

### 4.9 User Correction Feedback Loop

Every correction is a training signal. When a user edits a parsed field before confirming, or reports a parse error, the app can (with consent):

- Log the correction type (wrong amount / wrong merchant / wrong type / false parse)
- Associate it with the bank key and message template hash (not the raw text)
- Send anonymized correction reports to the admin panel for rule improvement
- Use reported templates in the Parser Lab to write/improve bank rules

**Privacy note:** Only anonymized structural corrections should leave the device — not raw SMS text, not amounts, not merchant names. See Section 13.

---

## 5. Where Parsing Should Happen

### 5.1 On-Device Parser (Primary)

The bank-specific rule engine and generic heuristic parser run **entirely on-device** in a Dart isolate. This is the correct primary path for all production parsing.

**Why on-device first:**
- Privacy: Raw SMS never leaves the device by default
- Speed: Zero network latency, works offline
- Reliability: No dependency on server availability
- Trust: Users can see that their messages stay on their phone (important for Arabic-speaking markets where privacy concerns are high)
- Cost: Zero per-parse server cost for the primary path

**The Dart isolate** provides a 2-second hard timeout. Any message that takes longer than 2 seconds to parse is treated as a parse failure and sent to pending. This prevents pathological regex or AI inputs from blocking the main thread.

### 5.2 Server AI Fallback (Optional, User-Controlled)

The AI fallback is an **opt-in feature**, not a default. Users who enable it agree to:
- Sending anonymized message text to Mali's servers for analysis
- Receiving AI-assisted categorization suggestions

What "anonymized" means in this context: card numbers, account numbers, personal names, and phone numbers are stripped before transmission. See Section 13.

The AI fallback **never returns a result directly to the database.** It returns a suggestion that goes through the pending confirmation queue. The user confirms or dismisses.

### 5.3 Admin Parser Lab (Server-Side Tooling)

Parser rules are authored and validated server-side via the admin panel. The Parser Lab (see Section 10) allows an admin to:
- Paste real (anonymized) SMS examples
- Test rules against them interactively
- Deploy approved rules to the remote catalog

The Parser Lab is a development and operations tool, not a runtime component.

### 5.4 What Must Never Happen

- Raw SMS uploaded to any server without explicit user consent
- AI fallback result auto-saved without user confirmation
- Parser rules bypassing the confidence engine
- Pending queue items surviving app uninstall without user action
- Raw SMS stored in any log, crash report, or analytics event

---

## 6. Exact Decision Flow

```
Receive SMS
│
├─ Is the sender ID on the known trusted bank list? ──────────────────── No ──▶ body keyword scan
│                                                                                     │
│                                                               Any keyword match? ──▶ No ──▶ treat as unknown sender
│
▼
Run Normalization
│
▼
Run Ignore Filter
│
├─ OTP / promo / scam / balance-inquiry keyword? ──────────────────────────────────────────────▶ IGNORED (no UI)
│
▼
Bank profile matched?
│
├─ Yes → Run bank-specific rule engine
│              │
│              ├─ Confidence ≥ 0.90 AND all 5 auto-confirm criteria met? ──────────────────────▶ AUTO_CONFIRM
│              │
│              └─ Confidence 0.70–0.89 ──────────────────────────────────────────────────────▶ PENDING
│
└─ No → Run generic heuristic parser
               │
               ├─ Generic confidence (always capped at 0.79) ≥ 0.70? ───────────────────────▶ PENDING
               │
               └─ Generic confidence < 0.70?
                              │
                              ├─ AI fallback enabled AND message looks like a transaction? ──▶ AI call
                              │              │
                              │              ├─ AI returns a result → PENDING (always, no exceptions)
                              │              └─ AI returns nothing → IGNORED
                              │
                              └─ AI fallback disabled → IGNORED
```

### 6.1 When to Auto-Confirm

All of the following must be true simultaneously:

1. Sender ID matched a known bank profile (not just body keywords)
2. Transaction type is not `unknown`
3. Exactly one strong amount candidate (no ambiguity)
4. Currency is explicit in the message (not defaulted)
5. Confidence score ≥ 0.90

If any condition fails, the result is `pending_confirmation`, not `auto_confirm`.

### 6.2 When to Pending

Any of the following:
- Bank profile matched but confidence 0.70–0.89
- Generic parser confidence 0.70–0.79 (capped)
- AI fallback returned a result (regardless of confidence)
- Auto-confirm criteria not fully met

### 6.3 When to Ignore

Any of the following:
- Ignore filter triggered (OTP, promo, scam, etc.)
- No amount extractable at all
- Generic confidence < 0.70 AND AI fallback disabled/failed
- AI fallback returned no result

### 6.4 When to Call AI

AI is called only when all of the following are true:
- The ignore filter did not trigger
- The message appears to contain at least one numeric amount
- At least one transaction-context keyword is present ("payment", "debit", "خصم", etc.)
- Both the bank-specific and generic parsers scored below 0.70
- The user has enabled AI fallback
- The device is online

---

## 7. AI Usage Strategy

AI is a powerful tool that fits into specific narrow roles within this architecture. Understanding where it helps and where it hurts is critical.

### 7.1 What AI Is Good At (For This Problem)

| Task | AI Value |
|------|----------|
| Classifying ambiguous message intent (transaction vs. OTP vs. promo) | High |
| Extracting merchant name from freeform text | High |
| Suggesting category from merchant name | High |
| Explaining why a parse failed (admin tooling) | High |
| Generating synthetic training SMS templates | High |
| Drafting new parser rules from example messages | High |
| Translating/normalizing regional currency aliases | Medium |
| Handling completely novel bank formats | Medium |

### 7.2 What AI Must Not Do

| Task | Why Not |
|------|---------|
| Auto-save financial transactions | Cannot verify correctness; one wrong save = user trust broken |
| Run as the primary parser in production | Too slow, too expensive, requires network, not offline |
| Access raw SMS text without user consent | Privacy violation |
| Set the auto-confirm gate | The gate must be deterministic and auditable |
| Override the confidence engine | AI confidence is not calibrated the same way as rule-based confidence |

### 7.3 Runtime AI Role (Production)

**Trigger:** Generic parser confidence < 0.70, message appears to be a transaction, AI fallback enabled.

**Input sent to server (anonymized):**
```json
{
  "text": "<anonymized SMS>",
  "context": {
    "sender_id": "CIB",
    "country": "EG",
    "locale": "ar-EG"
  }
}
```

**Expected server response:**
```json
{
  "is_transaction": true,
  "transaction_type": "payment",
  "amount": 60.00,
  "currency": "EGP",
  "merchant": "Fawry",
  "confidence": 0.82,
  "reasoning": "debit keyword 'خصم', amount followed by EGP, merchant after 'عند'"
}
```

**Client handling:**
- Response is validated (amount > 0, currency is known ISO code, type is in known enum)
- Confidence from AI is disregarded for gate purposes — result always goes to `pending_confirmation`
- If response is invalid or missing required fields → ignored

**Cost management:**
- AI fallback is only triggered if the message passes the basic transaction likelihood check
- Results are cached by message hash for 24 hours (avoid re-calling AI for duplicate notifications)
- Rate limited per device per day

### 7.4 Admin / Development AI Role

In the Parser Lab and admin tooling, AI plays a much larger role:

- **Rule generation:** Admin pastes 5–10 example messages from a bank. AI drafts a BankProfile rule set. Admin tests and edits it.
- **Coverage analysis:** AI flags gaps in the rule set by analyzing a golden corpus.
- **Anomaly detection:** AI reviews incoming correction reports and clusters them into template families.
- **Synthetic data generation:** AI generates variations of a confirmed template to expand the test corpus.

In these contexts, AI output is reviewed by a human admin before any rule is deployed. The human is always in the loop.

---

## 8. Dataset Strategy

The parser quality is ultimately bounded by the diversity and quality of the SMS examples it has been tested against. Building and maintaining a good dataset is a continuous operational effort.

### 8.1 Public Dataset Limitations

There is no large publicly available dataset of Arabic bank SMS messages. Existing financial NLP datasets:
- Are primarily English
- Focus on formal financial text, not SMS
- Do not contain bank-specific template variations
- Cannot be used as-is for training bank-specific rules

**Conclusion:** The Mali dataset must be built from scratch.

### 8.2 Real Anonymized SMS Collection

The highest-quality source is real SMS messages from real users, anonymized before storage.

**Collection flow:**
1. User opts into "Parser Improvement Program" (explicit, named, dismissible)
2. App intercepts SMS that were pending-confirmed or reported as parse errors
3. Before sending to server, the app strips: card numbers, account numbers, personal names, phone numbers (via regex patterns), preserving only: bank name, amounts, currency, merchant, date structure
4. Stripped message + correction (what the user confirmed the fields to be) is sent to the server
5. Admin reviews in the Parser Lab, labels it, adds to the golden corpus

**Key principle:** If you cannot guarantee a message is fully anonymized, do not collect it. Reject ambiguous cases on the device before upload.

### 8.3 Synthetic Template Generation

For banks where real-user contributions are sparse, AI can generate synthetic variations:

**Input:** One real example from a bank (confirmed correct)
**AI output:** 20 synthetic variations with different amounts, merchants, dates, card numbers, and whitespace patterns — all structurally equivalent

Synthetic messages are clearly tagged in the corpus and never count toward "real-world coverage" metrics. They are used only for regression testing, not for calibrating confidence thresholds.

### 8.4 Tester Contribution Flow

A small pool of volunteer testers (recruited from beta users) can:
- Submit anonymized SMS from their inbox via a dedicated in-app flow
- Label the correct fields manually
- Flag OTP/promo/scam messages they received that the parser wrongly flagged as transactions

Each submission goes through the same anonymization pipeline as the real collection flow. Testers should represent different countries, banks, and device locales.

### 8.5 User Correction Data

Every time a user edits a parsed field in the pending confirmation form, this is a correction event. The app records (not raw text):
- Which field was corrected (amount / merchant / type / currency)
- The bank key (if matched)
- Whether this is a new correction type for this bank or a repeat

Correction rates per bank are tracked in the admin panel. A bank with a correction rate > 5% needs a rule update.

### 8.6 Golden Corpus Structure

The golden corpus is the authoritative test dataset. It is version-controlled alongside the parser code. Every parser update must pass the full golden corpus before deployment.

**Corpus structure:**

```
test/
  engine/
    fixtures/
      bank_sms_golden_fixtures.dart   ← positive cases (real transactions)
      parser_gate_fixtures.dart        ← gate boundary cases
      ignore_fixtures.dart             ← OTP/promo/scam cases
      ambiguous_amount_fixtures.dart   ← amount ambiguity cases
```

**Fixture fields:**

| Field | Purpose |
|-------|---------|
| `id` | Stable unique identifier, never changes |
| `description` | Human-readable explanation of what this case tests |
| `rawSms` | The anonymized SMS text |
| `sender` | Sender ID (anonymized/fake bank names OK) |
| `expectedType` | TransactionType enum value |
| `expectedAmount` | Double, exact |
| `expectedCurrency` | ISO currency code |
| `expectedMerchant` | String or null |
| `expectedLast4` | String or null |
| `expectedBalance` | Double or null |
| `expectedOccurredAt` | DateTime or null |
| `expectedStatus` | autoConfirm / pending / ignored |
| `knownMerchantCategoryKey` | For testing final auto-confirm gating |

**Target corpus size:** 200+ real-world cases before v1.0 launch, growing to 500+ by 6-month mark.

---

## 9. Golden Tests

The golden test suite is a **contract**. Breaking it is a breaking change. No parser update ships without passing the full suite.

### 9.1 Test Categories

**Category 1 — Positive transaction parsing** (the happy path)

One test per bank per template variant. Each test asserts every extracted field exactly. These tests directly encode the accuracy contract for each bank.

Example fixture:
```
id: eg_cib_prepaid_fawry_debit
bank: CIB Egypt
SMS: "تم خصم 60.00EGP من بطاقة المدفوعة مقدماً رقم 4907 عند FAWRY..."
expected: amount=60.00, currency=EGP, type=payment, merchant=FAWRY, last4=4907, status=pending
```

**Category 2 — Negative tests (must be ignored)**

One test per ignore pattern. Asserts `status=ignored`. Tests that the ignore filter catches OTP, promo, scam, and balance-only messages correctly.

Critically: also test that the ignore filter does NOT fire on real transaction messages that happen to contain a phone number, a URL, or the word "code" in context (false ignore prevention).

**Category 3 — Ambiguous amount tests**

Messages with multiple numeric tokens where the correct transaction amount is not the first or largest number. Tests the amount candidate scoring logic.

Example: A message with a card number (4907), a small fee (2.50), the actual amount (60.00), and a balance (28.14). The correct extracted amount must be 60.00.

**Category 4 — Gate boundary tests**

Tests that sit exactly at the boundary between `pending` and `auto_confirm`. These are the most important safety tests. They assert that:
- Messages from unknown senders never auto-confirm
- Messages with ambiguous amounts never auto-confirm
- Messages from the generic path never auto-confirm
- Messages with unresolved currency never auto-confirm

**Category 5 — Regression tests**

Every bug that has ever been reported as a parse error becomes a test case. The `id` field of regression cases should reference the incident (e.g., `regression_cib_balance_confusion_2026_03`).

### 9.2 Running Tests

```bash
# Full golden suite
flutter test test/engine/

# Only bank-specific fixtures
flutter test test/engine/parser_quality_golden_test.dart

# Specific bank
flutter test test/engine/parser_quality_golden_test.dart --name "eg_cib"

# Ignore/gate tests only
flutter test test/engine/parser_gate_fixtures.dart
```

### 9.3 Test Discipline

- **Never adjust the expected output to match the parser output.** If a test fails, fix the parser.
- **Never delete a test because it's inconvenient.** If the behavior is intentionally changing, document why.
- **Add a test before fixing every parse bug.** Test first, then fix. This creates a permanent regression guard.
- **Review golden corpus additions the same way as code changes.** A bad expected output in the corpus is a bug.

---

## 10. Parser Lab in the Admin Panel

The Parser Lab is a first-class feature of the admin panel. It is the primary tool for developing, testing, and deploying parser rules.

### 10.1 Core Workflow

```
1. Collect example SMS (from user contributions, tester submissions, or manual input)
2. Anonymize (strip PII via guided form)
3. Label expected fields (transaction type, amount, currency, merchant, etc.)
4. Test against current parser (see current parse result vs. expected)
5. Identify rule gaps (which fields are wrong or missing)
6. Draft/edit rule (either manually or via AI suggestion)
7. Test updated rule (re-run parser with the draft rule applied)
8. Confirm correctness for all examples in the bank's fixture set
9. Approve rule for deployment
10. Rule is pushed to remote catalog (Supabase), versioned
11. App picks up new rule on next catalog sync
```

### 10.2 Parser Lab UI Components

**SMS Input Panel**
- Free-text paste area for raw SMS
- Sender ID input field
- Country/locale selector
- "Anonymize" button (highlights detected PII for manual review before saving)

**Parse Result View**
- Shows current parser output for the pasted SMS
- Fields displayed: type, amount, currency, merchant, last4, balance, date, confidence, gate, bank key matched
- Color coding: green = extracted, orange = defaulted, red = missing

**Expected Fields Form**
- Parallel form where admin enters what the correct result should be
- Diff view: current output vs. expected

**Rule Editor**
- Edit bank profile fields: senderIds, keywords, typeRules, amountRules, balanceRules, merchantRules, ignoreRules
- Regex syntax validated before saving
- Live preview: re-runs parse with draft rule on all saved examples for this bank

**Corpus Manager**
- List of all saved examples for the selected bank
- Filter by: has parse error, recently added, pending review
- Bulk re-test: runs current parser on all examples and shows pass/fail count

**Deployment Controls**
- "Approve and Deploy" button — sends rule update to Supabase catalog with incremented version
- Deployment history log
- Rollback to previous version button

### 10.3 Parser Lab Access Control

- Parser Lab is accessible only to authenticated admin users
- Deploying a rule requires admin confirmation (two-click: "Deploy" → "Confirm Deploy")
- All deployments are logged with admin email, timestamp, and diff
- No anonymous access

### 10.4 Parser Lab and AI Integration

An AI-assist button in the Rule Editor calls the server-side AI to:
- Analyze the bank's collected examples
- Suggest a BankProfile rule set (senderIds, keywords, typeRules, etc.)
- Explain which parts of the SMS it used for each field

The AI suggestion is displayed as a starting point, not a final result. The admin reviews, edits, and tests it before approving. AI cannot deploy rules directly.

---

## 11. Confidence Scoring

Confidence scoring is the mechanism that converts raw parse output into a gate decision. It must be deterministic, inspectable, and consistently calibrated.

### 11.1 Component Scores

Each extracted field contributes a component score based on how reliably it was extracted:

**Amount confidence**

| Extraction method | Score |
|-------------------|-------|
| Labeled by explicit amount keyword ("مبلغ", "amount") | 1.0 |
| Adjacent to currency token + transaction keyword | 0.85 |
| Only transaction keyword present | 0.70 |
| Only currency token present | 0.65 |
| No label, no currency, but plausible numeric format | 0.40 |
| Ambiguous (two competing candidates close in score) | −0.25 penalty on final |

**Currency confidence**

| Resolution method | Score |
|-------------------|-------|
| Explicit ISO code in message (EGP, SAR, AED) | 1.0 |
| Explicit Arabic alias normalized to ISO code | 0.95 |
| Inferred from bank profile country default | 0.60 |
| Defaulted from app account setting | 0.30 |

**Merchant confidence**

| Extraction method | Score |
|-------------------|-------|
| After known merchant preposition ("عند", "لدى", "At") | 0.90 |
| After "@" sign | 0.85 |
| After "Merchant:" label | 0.95 |
| Not extracted | 0.00 (does not block auto-confirm alone) |

**Transaction type confidence**

| Detection method | Score |
|-----------------|-------|
| Bank typeRules match | 1.0 |
| Global keyword match ("شراء", "payment", "transfer") | 0.90 |
| Inferred from message structure | 0.60 |
| Unknown | 0.00 |

**Sender confidence**

| Match quality | Score |
|---------------|-------|
| Exact sender ID match to known profile | 1.0 |
| Sender ID partial match or alias | 0.70 |
| Body keyword match (no sender ID) | 0.40 |
| No match | 0.00 |

### 11.2 Final Confidence Formula

```
base_score = 0.10
+ (bank_matched ? 0.15 : 0)
+ (sender_id_matched ? 0.10 : 0)
+ (amount_extracted ? 0.25 : 0)
+ (amount_unambiguous ? 0.10 : 0)
+ (type_identified ? 0.15 : 0)
+ (currency_explicit ? 0.10 : 0)
+ (merchant_extracted ? 0.10 : 0)
+ (date_extracted ? 0.05 : 0)
− (amount_ambiguous ? 0.25 : 0)

if (no bank match) → capped at 0.79
if (ai fallback path) → capped at 0.69
```

### 11.3 Calibration Notes

- Weights should be revisited quarterly using correction rate data from the admin panel
- A bank consistently scoring 0.88 should get its rules tightened to push it above 0.90 (or its correction rate investigated)
- The 0.90 auto-confirm threshold must never be lowered without a full corpus re-evaluation
- Category confidence is tracked separately (see Section 12) and does not affect the main gate

---

## 12. Categorization Strategy

Categorization is a secondary process that runs after parsing. It never blocks parsing and never affects the gate decision on its own. A transaction with an unknown category is still auto-confirmed if parsing confidence is high.

### 12.1 Categorization Sources (in priority order)

1. **User rule** — explicit user-defined mappings ("Fawry → Bills", "Careem → Transport"). Highest priority, always wins.
2. **Merchant database** — a curated map of merchant name → category key, bundled and synced via remote catalog. Covers top merchants for each supported country.
3. **AI category suggestion** — for merchants not in the database, an AI call (if enabled) suggests a category. Result goes into pending for user confirmation.
4. **Keyword heuristic** — generic category from transaction keywords (ATM withdrawal → "cash", "salary" → "income").
5. **Default** — "other" category. Always available as fallback.

### 12.2 Categorization and Auto-Confirm

**A transaction should never auto-confirm into the wrong category.** The following rules apply:

- If category is resolved from a user rule → auto-confirm category (user chose this mapping)
- If category is resolved from the merchant database → auto-confirm category (curated mapping)
- If category is AI-suggested → always `pending` for category review (even if parse was auto-confirm)
- If category is a keyword heuristic → auto-confirm category for high-confidence keywords ("salary" → income)
- If category is "other" → auto-confirm the transaction but mark category as needs-review in the UI

### 12.3 Merchant Database Structure

```
MerchantMapping {
  rawName: string          // exact or prefix match key
  categoryKey: string      // stable category identifier
  confidence: double       // 0.5–1.0, affects whether to auto-confirm category
  country: string?         // null = global, "EG" = Egypt-specific
  aliases: string[]        // alternative spellings/formats
}
```

The merchant database is part of the remote catalog and synced via Supabase. Admins can add/edit merchant mappings in the admin panel.

### 12.4 Category Keys (Stable Identifiers)

Category keys are stable strings, never UUIDs. They are referenced in parser rules, merchant mappings, and the database. Changing a key is a breaking migration.

Current keys: `restaurants`, `groceries`, `transport`, `fuel`, `bills`, `shopping`, `health`, `education`, `entertainment`, `subscriptions`, `transfers`, `cash`, `travel`, `gifts`, `kids`, `home`, `cafes`, `maintenance`, `income`, `other`

---

## 13. Privacy and Security

### 13.1 Data Minimization Principles

- The parser runs on-device. Raw SMS never leaves the device by default.
- Drift stores only the structured parsed output, not the raw SMS.
- The pending queue stores raw SMS temporarily only until the item is resolved.
- When a pending item is confirmed or dismissed, raw SMS is deleted immediately.
- No crash reporting tool (Sentry, etc.) should ever capture a raw SMS in its payload.

### 13.2 Anonymization Before Any Server Transmission

If a user opts into the Parser Improvement Program or AI fallback, the app must anonymize before transmission. Anonymization rules (applied on-device):

| Data type | Handling |
|-----------|---------|
| Card number (full) | Removed entirely |
| Card last 4 digits | Replaced with placeholder `****XXXX` |
| Account number | Removed entirely |
| IBAN | Removed entirely |
| Personal name (if detectable) | Replaced with `[NAME]` |
| Personal phone number (in body) | Replaced with `[PHONE]` |
| Reference/transaction number | Replaced with `[REF]` |
| OTP/code | Message rejected (ignore filter should have caught this first) |
| Amounts and currency | Preserved (essential for parser improvement) |
| Merchant name | Preserved |
| Bank name / sender ID | Preserved |

### 13.3 Consent Requirements

- Parser Improvement Program: explicit opt-in, named feature, with clear description of what is collected and why
- AI fallback: separate explicit opt-in, distinct from Parser Improvement Program
- Both opt-ins: dismissible at any time, with immediate effect (no buffered data sent after opt-out)
- Opted-out users: no collection, no transmission, no impact on functionality

### 13.4 Security Considerations

- SMS content in memory is treated as sensitive. No logging of raw SMS text in debug or release builds.
- The remote catalog is signed (HMAC or versioned hash) to prevent rule injection attacks via a compromised Supabase connection.
- The AI fallback endpoint requires authentication (user token), rate limiting, and returns only structured JSON — never raw text echoes.
- Bank profile updates from the remote catalog are validated against a schema before being applied.

---

## 14. Multi-Country and Multi-Bank Scaling

### 14.1 Target Markets

**Phase 1 (MVP — current)**

| Country | Banks | Wallets | Language |
|---------|-------|---------|---------|
| Saudi Arabia | SNB, AlRajhi, Riyad | STC Pay | Arabic (ar-SA), English |
| Egypt | CIB, NBE, Banque Misr | Fawry, Vodafone Cash | Arabic (ar-EG), English |

**Phase 2 (3–6 months)**

| Country | Banks | Wallets |
|---------|-------|---------|
| UAE | ADCB, Emirates NBD, FAB, Mashreq | Apple Pay, Etisalat Wallet |
| Kuwait | NBK, KFH, Burgan | Tap |
| Qatar | QNB, QIIB, CBQ | — |

**Phase 3 (6–12 months)**

| Country | Notes |
|---------|-------|
| Bahrain | Smaller market, BisB, NBB |
| Oman | BankMuscat, NBO |
| Jordan | Arab Bank, Cairo Amman Bank |

### 14.2 Scaling Approach

**Do not try to cover everything at once.** Each new bank requires:
1. Collecting real examples (at least 10–20 per template variant)
2. Writing and testing a BankProfile
3. Adding to the golden corpus (at least 5 positive cases, 2 negative cases)
4. Deploying to remote catalog
5. Monitoring correction rate post-deployment

Prioritize banks by user base size within the target countries. Use the Parser Lab to systematically process contributed examples.

### 14.3 Multi-Language Handling

The parser supports Arabic-English mixed messages natively. The normalization layer handles:
- Eastern Arabic numerals → Western
- Arabic currency aliases → ISO codes
- RTL/LTR mixed text (ignored for parsing; relevant only for display)

For purely English messages (common in UAE, some Egyptian banks), the generic parser handles them well because English parser rules (amount, merchant, date patterns) are already implemented.

For messages in other scripts (rare in the target markets but possible for expats), the ignore filter should safely route them to `ignored` if no amount is extractable.

### 14.4 Currency Handling

Each bank profile defines its currency aliases. The global normalization layer handles the most common ones. Unknown currencies default to the account's base currency (with low confidence — never auto-confirms with a defaulted currency).

**Multi-currency accounts:** The app already supports multi-currency accounts. The parser should prefer the explicit currency from the SMS over the account default. If no currency is in the SMS, and the account has a single currency, use that. If the account has multiple currencies configured, fall to pending until the user selects.

---

## 15. MVP Plan

### 15.1 Build Now

These components are directly on the critical path for launch quality:

| Component | Priority | Effort |
|-----------|----------|--------|
| Bank profiles: SNB, AlRajhi, Riyad, STC Pay, CIB, NBE | P0 | Low (rules) |
| Normalization layer (Arabic numerals, currency aliases, diacritics) | P0 | Low |
| Ignore filter (OTP, promo, scam) | P0 | Low |
| Amount candidate scoring with ambiguity detection | P0 | Medium |
| Confidence engine with thresholds | P0 | Medium |
| Pending confirmation queue (Drift table + UI card) | P0 | Medium |
| Golden test suite ≥ 50 cases | P0 | Medium |
| User correction tracking (local, no upload) | P1 | Low |
| Merchant database (top 50 merchants per country) | P1 | Low |

### 15.2 Delay

These are valuable but not required for launch:

| Component | Reason to Delay |
|-----------|----------------|
| Parser Lab admin UI | Important but not user-facing; can use Supabase directly for now |
| AI fallback | Requires privacy infrastructure; risky to rush |
| User correction uploads | Requires consent framework; not needed for launch |
| Automated synthetic data generation | Nice-to-have for corpus expansion |
| UAE/Gulf bank profiles | Can ship as remote catalog update post-launch |

### 15.3 What Is Risky

These decisions carry technical or business risk:

| Decision | Risk | Mitigation |
|----------|------|-----------|
| Lowering auto-confirm threshold for higher auto-save rate | Wrong auto-saves destroy user trust | Never lower; increase by improving rules |
| Shipping AI fallback at launch | Privacy, cost, latency, scope | Keep AI fallback as post-launch opt-in feature |
| Covering too many banks at launch | Low-quality rules cause errors | Better to cover 10 banks well than 50 banks poorly |
| Storing raw SMS in any persistent form | Privacy and security risk | Delete raw SMS immediately after pending resolution |
| Using `hashCode` for feature flag bucketing | Unstable across Dart versions | Already using SHA-256; maintain this |

---

## 16. 6-Month Roadmap

### Month 1–2: Foundation

- [ ] Golden corpus: 100+ cases across 6 banks (SA + EG)
- [ ] Full normalization layer tested and covered
- [ ] All ignore patterns covered by negative tests
- [ ] Amount ambiguity tests written and passing
- [ ] Pending confirmation queue shipped and tested
- [ ] Correction tracking (local, no upload) instrumented
- [ ] Parser Lab v1: paste SMS, see parse result, edit bank rule manually

### Month 3–4: Quality

- [ ] Golden corpus: 200+ cases
- [ ] Parser Lab v2: AI rule suggestion, live preview, corpus manager
- [ ] UAE bank profiles (ADCB, Emirates NBD, FAB) via remote catalog
- [ ] User correction data upload (with explicit consent flow)
- [ ] Admin panel: correction rate dashboard per bank
- [ ] Merchant database: 200+ merchants across SA + EG

### Month 5–6: Scale

- [ ] AI fallback (opt-in, pending-only, anonymized input)
- [ ] Golden corpus: 300+ cases
- [ ] Kuwait and Qatar bank profiles
- [ ] Parser Lab v3: rule deployment workflow, version history, rollback
- [ ] Automated regression test run on every catalog deploy
- [ ] Parser accuracy dashboard (auto-confirm rate, correction rate, coverage) in admin panel

---

## 17. Success Metrics

These are the metrics that define whether the parser is working well. Track them in the admin panel and review monthly.

### 17.1 Accuracy Metrics

| Metric | Definition | Target |
|--------|-----------|--------|
| Amount accuracy rate | % of auto-confirmed transactions where amount is correct | ≥ 99.9% |
| False auto-save rate | % of auto-confirmed transactions that users edit or delete | ≤ 0.1% |
| OTP false positive rate | % of OTP/promo messages that reach the pending queue | ≤ 0.01% |
| False ignore rate | % of real transactions that are silently ignored | ≤ 0.1% |

### 17.2 Coverage Metrics

| Metric | Definition | Target |
|--------|-----------|--------|
| Bank coverage | % of users' banks that have a matched profile | ≥ 80% at launch |
| Auto-confirm rate | % of real transactions that auto-confirm | ≥ 60% for covered banks |
| Pending rate | % of real transactions that go to pending | ≤ 35% for covered banks |
| Correction rate per bank | % of confirmed transactions where user edited a field | ≤ 5% per bank |

### 17.3 Corpus Metrics

| Metric | Definition | Target |
|--------|-----------|--------|
| Golden corpus size | Total number of labeled fixtures | ≥ 200 at launch, ≥ 500 by month 6 |
| Corpus pass rate | % of golden fixtures passing on current parser | 100% (hard gate) |
| Bank coverage in corpus | Number of distinct banks with ≥ 5 golden fixtures | ≥ 6 at launch |

### 17.4 Operational Metrics

| Metric | Definition | Target |
|--------|-----------|--------|
| Parser p99 latency (on-device) | 99th percentile parse time on mid-range device | ≤ 200ms |
| Remote catalog sync success rate | % of sync attempts that succeed | ≥ 98% |
| Rule deployment cycle time | Time from correction report to deployed rule fix | ≤ 48 hours |

---

## 18. Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                          Device (On-Device)                      │
│                                                                   │
│  ┌──────────┐    ┌──────────────┐    ┌─────────────────────┐    │
│  │ SMS Inbox│───▶│ Normalization│───▶│   Ignore Filter     │    │
│  └──────────┘    │    Layer     │    │ (OTP/Promo/Scam)    │    │
│                  └──────────────┘    └─────────┬───────────┘    │
│                                                │                  │
│                                         Ignored│                  │
│                                    (no UI) ◀───┤                  │
│                                                │ Not ignored       │
│                                                ▼                  │
│                                    ┌─────────────────────┐        │
│                                    │  Bank/Sender        │        │
│                                    │  Detection          │        │
│                                    └────────┬────────────┘        │
│                                             │                     │
│                     ┌───────────────────────┴──────────────┐      │
│                     │ Matched                               │      │
│                     │ bank profile                No match │      │
│                     ▼                                       ▼      │
│           ┌─────────────────┐                 ┌────────────────┐  │
│           │ Bank-Specific   │                 │ Generic        │  │
│           │ Rule Engine     │                 │ Heuristic      │  │
│           │                 │                 │ Parser         │  │
│           │ conf ≥ 0.90 ───▶ AUTO_CONFIRM     │ (max 0.79)     │  │
│           │ conf 0.70–0.89  │                 │                │  │
│           └────────┬────────┘                 └───────┬────────┘  │
│                    │ Pending                          │           │
│                    │ or too low                 conf < 0.70       │
│                    ▼                                  │           │
│           ┌────────────────┐              ┌───────────▼───────┐  │
│           │ Confidence     │              │ AI Fallback       │  │
│           │ Engine         │              │ Eligible?         │  │
│           └────────┬───────┘              └───────┬───────────┘  │
│                    │                              │               │
└────────────────────│──────────────────────────────│───────────────┘
                     │ PENDING                       │ AI needed
                     ▼                              ▼
           ┌──────────────────┐        ┌─────────────────────────┐
           │ Pending          │◀───────│  AI Server Fallback     │
           │ Confirmation     │ always │  (Supabase Edge Fn)     │
           │ Queue (Drift)    │ pending│  Anonymized input only  │
           └────────┬─────────┘        └─────────────────────────┘
                    │ User confirms / edits
                    ▼
           ┌──────────────────┐
           │ Transactions     │
           │ (Drift — final)  │
           └──────────────────┘
                    │ Correction feedback
                    ▼
           ┌──────────────────┐        ┌─────────────────────────┐
           │ Correction       │───────▶│  Admin Panel            │
           │ Report (anonymiz)│        │  Parser Lab             │
           └──────────────────┘        │  Rule Editor            │
                                       │  Golden Corpus Manager  │
                                       │  Deploy to Catalog      │
                                       └──────────┬──────────────┘
                                                  │ Rule update
                                                  ▼
                                       ┌─────────────────────────┐
                                       │  Supabase               │
                                       │  Remote Catalog         │
                                       │  (catalog_versions)     │
                                       └──────────┬──────────────┘
                                                  │ Sync on next open
                                                  ▼
                                         Back to device ↑ (Drift)
```

**Data flow summary:**

- Raw SMS: device only (never leaves unless AI fallback opted in, and then anonymized)
- Parsed output: Drift on device
- Correction reports: anonymized, uploaded on consent only
- Parser rules: authored in admin panel → Supabase catalog → device Drift via sync
- AI calls: anonymized text → server edge function → structured JSON → pending queue

---

## 19. Actionable Next Steps for Mali

These are the highest-leverage next actions, ordered by priority:

### Immediate (This Sprint)

1. **Grow the golden corpus to 50+ cases.** Cover all currently supported banks (SNB, AlRajhi, Riyad, STC Pay, CIB, NBE) with at least 5 positive cases and 2 negative cases each. This is the single most valuable investment right now.

2. **Add the normalization test suite.** The normalizer is the foundation of everything. Every currency alias, numeral conversion, and whitespace rule should have a unit test.

3. **Add dedicated ignore filter tests.** One test per ignore category (OTP, promo, scam, balance-only). Include false-ignore prevention tests.

4. **Add Banque Misr and QNB Al Ahli Egypt profiles.** These two banks together with CIB and NBE cover the majority of Egyptian retail banking SMS.

5. **Add "المتاح" globally as a balance word.** (Already done in this session.) Extend the test corpus to cover other Egyptian-style balance formats.

### Near-Term (Next 4 Weeks)

6. **Ship the pending confirmation UI card.** The pending queue is implemented in Drift; the home screen UI card for reviewing pending transactions is the user-facing piece that completes the flow.

7. **Instrument local correction tracking.** Log which fields users edit in the pending confirmation form, keyed by bank profile. This data is essential for knowing which rules to improve first.

8. **Write the Parser Lab v1.** Even a minimal version — paste SMS, see parse output — dramatically accelerates rule development. It does not need rule editing in v1; read-only is enough to start.

9. **Add UAE bank profiles (ADCB, Emirates NBD).** The UAE is the third-largest target market. Even two banks gives meaningful coverage.

### Medium-Term (Months 2–3)

10. **Build the AI fallback infrastructure.** Design the anonymization pipeline, the Edge Function endpoint, and the consent flow before writing any AI code. Privacy architecture first.

11. **Build the correction report upload flow.** With consent infrastructure in place, begin collecting anonymized correction reports. This is the foundation of continuous improvement.

12. **Deploy Parser Lab v2** with rule editing, AI suggestions, and corpus management. This is the tool that scales the team's ability to add bank coverage without requiring a developer for every new bank.

13. **Set up parser accuracy dashboard.** Track auto-confirm rate, correction rate, and corpus pass rate per bank in the admin panel. This makes quality visible and actionable.

### Long-Term (Months 4–6)

14. **Ship AI fallback as an opt-in feature.** With privacy infrastructure in place and the Parser Lab generating high-quality rules, the AI fallback serves the genuinely long tail of uncovered banks.

15. **Target 500-case golden corpus.** With user contributions and synthetic data generation, this should be achievable by month 6. At 500 cases, the corpus provides statistically meaningful coverage of the supported banks.

16. **Publish parser coverage page in-app.** Let users see which banks Mali supports and which messages it can auto-confirm. Transparency builds trust, and a public list creates accountability for the team to keep improving.

---

*This document is a strategic reference. It should be reviewed and updated quarterly as the parser evolves, new banks are added, and metrics data becomes available. Convert specific items into implementation tasks using the project's task tracking system.*
