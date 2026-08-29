
---

## F-013 — RETRACTION AND REPLACEMENT

**The original F-013 claim was wrong and is withdrawn.**

Withdrawn text: *"There is no parser for deposits, salary, incoming transfers, or
refunds — those are always manual entry."*

**Why it was wrong.** Transaction direction is not decided by the catalog at all.
`ParserEngine._detectType` (`app/lib/engine/parser/parser_engine.dart:203`) checks
the bank profile's `typeRules` first, then falls through to a hardcoded keyword
ladder compiled into the engine:

```dart
if (_containsAny(lower, ['راتب', 'إيداع', 'ايداع', 'deposit', 'salary'])) {
  return TransactionType.income;
}
```

Verified empirically against the compiled engine — «تم إيداع راتب بمبلغ 12,500.00
ريال…» returns `type=income, amount=12500` with no `credit` parser anywhere in the
catalog. Income capture works.

**Replacement finding — F-013b · LOW · product hygiene.** All 12 catalog parsers
are `transaction_type = 'debit'`, and `parser_golden_tests.expected_type` already
CHECKs `('debit','credit','balance_inquiry','ignored')`. So the catalog does not
describe credit flows even though the schema provides for it. This is a
completeness gap in the catalog, **not** a functional gap in capture — the engine
compensates with built-in keywords. Its real significance is as evidence for
**F-016**: the catalog is not what drives parsing.

## F-015 — Merchant extraction swallows the trailing date clause · MEDIUM · product

The app's own built-in AlRajhi example parses to a contaminated merchant:

```
input:    تم خصم مبلغ 350.00 ريال من حسابك لدى STARBUCKS COFFEE بتاريخ 16/06/2026. الرصيد المتاح: 4,250.00 ريال
merchant: "STARBUCKS COFFEE بتاريخ 16/06/2026."      ← expected "STARBUCKS COFFEE"
```

Everything else is correct: `amount=350`, `currency=SAR`, `type=payment`,
`balanceAfter=4250`, `occurredAt=2026-06-16`, `confidence=1`. The date extractor
finds the date correctly; the merchant extractor simply does not stop before it.

**Not a staleness artifact** — reproduced identically on the June lab artifact and
on a fresh `dart compile js` of the current engine.

**Impact.** Merchant strings are the key for auto-categorisation and for merchant
grouping. Because the contaminated value embeds the transaction date, *every*
purchase produces a unique merchant. Categorisation cannot learn, merchant
history cannot group, and the transaction list shows a date inside the merchant
name. Confidence is reported as `1` (maximum) while the field is wrong.

**Reproduction** (no app or device required):

```bash
node -e '
globalThis.self=globalThis; globalThis.window=globalThis;
import("/path/to/admin/public/parser_lab.js").then(async()=>{
  await new Promise(r=>setTimeout(r,300));
  console.log(globalThis.parseSms("تم خصم مبلغ 350.00 ريال من حسابك لدى STARBUCKS COFFEE بتاريخ 16/06/2026. الرصيد المتاح: 4,250.00 ريال","alrajhi"));
});'
```

## F-016 — Catalog regex patterns are never used for parsing · **HIGH** · product

`sender_pattern` and `message_pattern` — the two fields the Admin parser editor
exists to manage — are **never matched against a message on the device.**

The full device-side lifecycle, `app/lib/core/backend/rules_client.dart:97-107`:

```dart
final senderPattern  = row.read<String>('sender_pattern');
final messagePattern = row.read<String>('message_pattern');
if (_cachedRegex('$parserId:sender',  senderPattern)  == null ||
    _cachedRegex('$parserId:message', messagePattern) == null) {
  continue;                       // syntax check only
}
draft.applyParser(
  transactionType: row.read<String>('transaction_type'),
  extractedFields: _jsonObjectMap(row.read<String>('extracted_fields')),
);                                // ← patterns are not passed on
```

They are compiled once purely to prove they are *syntactically valid*, then
discarded. `applyParser` receives only `transaction_type` and `extracted_fields`.

What the catalog actually contributes is then reduced to **hardcoded keyword
lists** selected by those two fields:

| catalog field | effect on device |
|---|---|
| `transaction_type: 'debit'` | installs `['debit','purchase','خصم','شراء']` |
| `extracted_fields` has key `merchant` | installs `['merchant','لدى','At']` |
| `extracted_fields` has key `amount` | installs `['amount','مبلغ','قيمة']` |
| `extracted_fields` has key `balance` | installs `['balance','available','الرصيد','المتاح']` |
| `extracted_fields` has key `date` | installs `['date','في','on']` |
| `sender_pattern` | **unused** (validity check only) |
| `message_pattern` | **unused** (validity check only) |
| `priority` | `ORDER BY` only, then discarded |

Only the *presence of a key* in `extracted_fields` matters — never its value.
Confirmed exhaustive: grepping `app/lib` for `message_pattern|messagePattern|
sender_pattern|senderPattern` outside tests returns only the sync/storage layer
(`catalog_daos.dart`, `app_database.dart`) and the discard site above.

### Consequences

1. **The Admin parser editor cannot fix a parsing bug.** Rewriting
   `message_pattern` changes nothing on device so long as it still compiles.
   F-015 is exactly such a bug — and it is unfixable from the Admin.
2. **Two parsers for one bank that differ only in patterns are indistinguishable**
   after `applyParser`; they collapse into the same profile.
3. **F-012 is overstated in one direction and understated in another.** The 124
   banks without a parser still produce a profile (the query `LEFT JOIN`s), just
   with empty rule sets — and the engine's global keyword fallback still fires.
   Conversely, the 12 banks "with" a parser gain only generic keyword lists, not
   bank-specific matching.
4. **The `/parsers` release gate is theatre.** `catalog-delta` withholds parsers
   that have not "passed" validation (F-011), gating a field that carries almost
   no behaviour.

### Assessment

This is the root cause behind F-011, F-013b and F-015 alike: the Admin presents a
catalog-driven parsing system, and the device runs a keyword-driven engine that
reads four scalars from that catalog. Either the engine is changed to apply the
authored regexes, or the Admin must stop presenting pattern editing as the way
parsing is controlled. This needs a product/architecture decision, not a patch.
