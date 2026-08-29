<!-- PROVENANCE: copied from `demo-docker/AUDIT_HANDOFF_F-016.md`, which is an untracked local
     demo/working directory. Audit handoff for F-016.
     Tracked here so the authoritative artifact survives loss of that
     directory. The original is left in place; this copy is the one of
     record. -->

# AUDIT HANDOFF — F-016

**Catalog regex rules are behaviourally dead: `sender_pattern` and `message_pattern` never participate in parsing.**

| | |
|---|---|
| **Severity** | **HIGH — systemic product / architecture** |
| Raised during | Guided QA, Phase 17 (Admin), tests Q17-03 / Q17-04 |
| Discovered | 2026-08-26 |
| Environment | Local Docker demo (`qirsh-demo`). No remote contact. Read-only investigation. |
| Related | F-011 (validation badge), F-012 (bank coverage), F-013b (no credit rules), F-015 (merchant contamination) |
| Remediation | **Not attempted.** No parser code, catalog row, Admin file, or Main/Audit source was modified. |

---

## 1. Claim

The two fields the Admin parser editor exists to author — `sms_parsers.sender_pattern`
and `sms_parsers.message_pattern` — are compiled once to check that they are
*syntactically valid regular expressions*, then discarded. They are never matched
against an SMS. Parsing is performed by a keyword engine compiled into the app.

Consequence: **a parsing defect cannot be fixed by editing rules in the Admin
dashboard**, which is the sole purpose that dashboard page serves.

---

## 2. Runtime path proving the fields are discarded

`app/lib/core/backend/rules_client.dart` — `localBankProfiles()`, the only device
consumer of the synced catalog. Lines 97–107:

```dart
final senderPattern  = row.read<String>('sender_pattern');
final messagePattern = row.read<String>('message_pattern');
if (_cachedRegex('$parserId:sender',  senderPattern)  == null ||
    _cachedRegex('$parserId:message', messagePattern) == null) {
  continue;                        // validity gate only
}

draft.applyParser(
  transactionType: row.read<String>('transaction_type'),
  extractedFields: _jsonObjectMap(row.read<String>('extracted_fields')),
);                                 // ← patterns are NOT passed on
```

`_cachedRegex` returns `null` only on `FormatException` (line ~135). Its return
value is used for nothing else. Both locals die at the end of the loop iteration.

`_RemoteBankProfileDraft.applyParser` (same file, ~line 335) then maps the two
surviving scalars onto **hardcoded keyword lists**:

```dart
typeRules.putIfAbsent(type, () => <String>{}).addAll(
  switch (type) {
    TransactionType.payment => const ['debit', 'purchase', 'خصم', 'شراء'],
    TransactionType.income  => const ['credit', 'salary', 'إيداع', 'راتب'],
    ...
  });
if (extractedFields.containsKey('merchant')) {
  merchantRules.addAll(const ['merchant', 'لدى', 'At']);
}
```

Note `containsKey` — only the **presence of a key** in `extracted_fields` has any
effect. The mapped value is never read.

### Exhaustiveness

Grepping `app/lib` for `message_pattern|messagePattern|sender_pattern|senderPattern`
outside tests yields three sites only:

| file | role |
|---|---|
| `data/catalog/catalog_daos.dart` | sync + upsert into Drift (storage) |
| `data/db/app_database.dart:2156` | column declaration |
| `core/backend/rules_client.dart:97-100` | the discard site above |

There is no fourth consumer. The values travel server → Drift → a validity check →
oblivion.

### The one real runtime effect

A pattern that is *syntactically invalid* triggers `continue`, which skips
`applyParser` entirely — silently removing that bank's contribution to
`typeRules`/`amountRules`/`merchantRules`. Nothing is logged and no error surfaces;
the bank simply degrades to the engine's global keyword fallback.

So the only way to change device behaviour by editing a pattern is **to break it**.
Editing it correctly does nothing.

---

## 3. Empirical check — 4 examples, 4 divergences

Method: the current engine was compiled to JS from unmodified sources
(`dart compile js app/tool/parser_lab_entry.dart -O2 -o <scratchpad>/parser_lab_current.js`)
and executed headlessly. Catalog rules were read from the demo database and
evaluated separately against the same inputs. Nothing was written anywhere.

Inputs are the Admin Parser Lab's own built-in examples.

### 3.1 مدفوعات الراجحي — sender `alrajhi`

```
تم خصم مبلغ 350.00 ريال من حسابك لدى STARBUCKS COFFEE بتاريخ 16/06/2026. الرصيد المتاح: 4,250.00 ريال
```

| | engine (actual) | catalog rule (claimed) |
|---|---|---|
| message matches? | — | **NO** |
| type | `payment` | `debit` |
| amount | `350` | — (no match) |
| merchant | `"STARBUCKS COFFEE بتاريخ 16/06/2026."` | — (no match) |
| balance | `4250` | `extracted_fields` has **no `balance` key** |
| confidence | `1` → auto-recorded | — |

The AlRajhi `message_pattern` requires `(?:شراء|دفع|Purchase|Payment)`. The message
says **خصم**, which is absent from that alternation. **The catalog rule for AlRajhi
cannot match AlRajhi's own debit SMS** — and this has never been noticed because the
rule is never executed. The engine parses it anyway at maximum confidence.

Two further divergences: the engine extracts a balance the catalog does not declare,
and the merchant is contaminated (**F-015**).

### 3.2 تحويل الأهلي — sender `snb`

```
تم تحويل مبلغ 1,200.00 SAR من حسابك. الرصيد: 8,500.00 SAR. 2026-06-16 09:30
```

| | engine (actual) | catalog rule (claimed) |
|---|---|---|
| message matches? | — | **NO** |
| type | **`transfer`** | **`debit`** |
| amount | `1200` | — (no match) |
| balance | `8500` | — (no match) |
| confidence | `1` → auto-recorded | — |

Same alternation failure. The engine reaches `transfer` through its global fallback
ladder, directly contradicting the catalog's declared `transaction_type = 'debit'`.

### 3.3 شراء دولي — sender `d360`

```
Purchase: USD 29.99 (SAR 112.45)
At: Netflix
Available Balance: SAR 3,400.00
2026-06-16
```

**D360 exists in `banks` but has zero rows in `sms_parsers`.** The engine parses it
flawlessly regardless: `type=payment`, `amount=112.45 SAR` (correctly preferring the
billing currency over `USD 29.99`), `merchant="Netflix"`, `balanceAfter=3400`,
`confidence=1`.

A bank with **no catalog rule at all** parses as well as one with a rule. This is the
cleanest single demonstration that the catalog is not what drives parsing.

### 3.4 رمز تحقق — no sender

```
رمز التحقق الخاص بك هو 492837. لا تشاركه مع أحد.
```

Correctly rejected (`isTransaction=false`) — by the engine's built-in ignore rules,
with no catalog involvement.

### Summary

| examples with a catalog rule | 3 |
| whose `message_pattern` actually matched | **0** |
| examples with no catalog rule that parsed anyway | **1 of 1** |
| fields diverging from the catalog contract | type, amount, merchant, balance |

**Scope caveat, stated plainly:** the runtime probe executed `parser_lab_entry.dart`,
which passes `BankProfiles.all` (31 hardcoded profiles). It therefore demonstrates
engine behaviour directly. The claim about the *device* path rests on the source
reading in §2, which is unambiguous — `applyParser` cannot use patterns it is never
given. A device-side confirmation is listed as follow-up work in §7.

---

## 4. Affected banks

**All 12 catalog parsers, and all 136 banks.**

The mechanism is in the shared mapping layer, not in any individual rule, so no
parser is exempt. Coverage context (F-012): 12 of 136 banks have a rule at all —
EG 8/36, SA 4/22, and zero across AE, IQ, KW, QA, BH, JO, OM and all non-Arab
markets. Those 124 banks already run on global keyword fallback, which is what the
other 12 effectively run on too.

Parsers with rules: `snb`, `cib_eg`, `nbe`, `alrajhi`, `banque_misr`, `qnb_alahli`,
`stcpay`, `vodafone_cash`, `riyad`, `etisalat_cash`, `orange_money`, `fawry`.

---

## 5. Exact dead fields

| field | status on device |
|---|---|
| `sms_parsers.sender_pattern` | **dead** — validity check only |
| `sms_parsers.message_pattern` | **dead** — validity check only |
| `sms_parsers.priority` | **dead** — `ORDER BY` in the query, then discarded |
| `sms_parsers.extracted_fields` *(values)* | **dead** — only `containsKey` is consulted |
| `sms_parsers.language` | not read by `localBankProfiles` |
| `sms_parsers.transaction_type` | **live** — selects a hardcoded keyword list |
| `sms_parsers.extracted_fields` *(key names)* | **live** — presence toggles keyword lists |
| `sms_parsers.is_active` / `is_deleted` | **live** — `WHERE` clause |

Six of eight authored fields carry no behaviour. The Admin edit form presents them
as equals.

---

## 6. User and operator impact

**Operators.** The Parsers page and its edit form constitute the entire mechanism
offered for controlling how bank SMS is read. That mechanism does not work. An
operator who reads a defect report, opens the rule, corrects the regex and saves has
changed nothing — and receives no signal to that effect. `catalog-delta` will
faithfully ship the corrected rule to every device, where it will be discarded again.

**F-015 is the concrete case.** Merchant strings for single-line AlRajhi purchases
absorb the trailing date clause (`"STARBUCKS COFFEE بتاريخ 16/06/2026."`), so every
purchase yields a unique merchant. Auto-categorisation cannot learn and merchant
history cannot group. The obvious fix — tighten `message_pattern`'s merchant
capture — is unavailable. It requires an app release.

**Compounding gates.** `validation_status` gates catalog delivery (F-011) over
fields that carry almost no behaviour, and all 12 parsers were granted `passed`
wholesale by `0004_parser_lab.sql:15` with `golden_test_count = 0` and
`validated_by = NULL`. `parser_golden_tests` holds 0 rows and no Admin code path
references it. So the safety system guards dead fields and has itself never run.

**End users.** Capture works — the engine is competent and handled all four
examples sensibly. The exposure is that per-bank tuning is impossible without an app
release, and quality regressions are invisible until a user reports them.

---

## 7. Architectural options (for later decision — not recommendations to execute now)

**A. Make the engine honour the catalog.** Thread `senderPattern`/`messagePattern`
into `BankProfile` and apply them ahead of keyword matching, keeping keywords as
fallback. Delivers on the promise the Admin already makes. Highest risk: every
authored rule becomes live at once, and §3 shows at least two would then *reject*
messages the engine currently accepts. Needs the golden-test corpus (F-011) built
**first** — this option is unsafe without it.

**B. Correct the Admin to describe reality.** Demote pattern editing, surface
`transaction_type` and the `extracted_fields` key set as the live controls, and mark
the rest read-only/advisory. Cheap and honest; abandons remote parser tuning.

**C. Server-side parsing.** Route capture through the existing `parse-sms` Edge
Function so rules execute where they are authored. Already wired as an AI fallback
(`captured_message_processor.dart:122`). Changes the privacy posture — message text
would leave the device on the primary path, not just the fallback.

**D. Ship the engine as versioned data.** Treat compiled rule sets as catalog
artifacts. Largest change; the only one that makes parsing behaviour fully
updatable without a release.

**Prerequisite common to A, C and D:** a populated `parser_golden_tests` corpus plus
a runner, so that any change to parsing can be regression-tested. Today there is no
way to tell whether a rule change improves or breaks capture.

### Follow-up verification still owed

1. Device-path confirmation: instrument `localBankProfiles()` on a real device and
   assert the resulting `BankProfile` carries no pattern-derived rules.
2. Confirm the invalid-regex degradation path (§2) fails silently in a running app.
3. Establish whether `extracted_fields` values were ever intended to be read, or
   were specified as documentation.

---

## 8. Provenance

All findings are from reading source and from executing an unmodified compile of the
current engine against local demo data. No parser code, catalog row, Admin file, or
Main/Audit source was modified. No remote project was contacted.

Full evidence, including F-011, F-012, F-013 (retracted), F-013b and F-015, is in
`DEMO_FINDINGS.md`.
