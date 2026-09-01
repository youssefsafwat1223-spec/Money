# `merchant_alias_key_v1` / `merchant_domain_key_v1` — normative specification

**Status: FROZEN.** This document defines two lookup-key functions by exact
code-point behaviour. Two implementations exist — Dart (offline client) and
PostgreSQL (authoritative write-time derivation and the uniqueness index) — and
they must produce byte-identical output for every input.

**Never edit a `_v1` function.** A change is a new version: a `_v2` function, a
transactional re-key of every alias row, a rebuild of the partial unique index,
and client gating on `key_version`. Editing in place silently invalidates every
device cache and every stored key, and an expression index does NOT recompute
itself when the function behind it changes.

---

## Why a new contract instead of reusing an existing normalizer

The repository already contains **five** merchant normalizers. None is usable
here, and all five must keep their current behaviour.

| # | Location | Behaviour | Why not reusable |
|---|---|---|---|
| 1 | `AppDatabase._normalizeMerchant` (`app_database.dart:3135`) | uppercase, strip ASCII digits, collapse whitespace | Backs `merchants.normalized_name UNIQUE` — a **persisted local identity**. Changing it re-keys existing user rows. |
| 2 | `TransactionDedup.normalizeMerchant` (`transaction_dedup.dart:39`) | identical to 1 | Feeds the dedup **hash**. Changing it breaks matching against every historical hash. |
| 3 | `MerchantCategoryMap.normalize` (`merchant_category_map.dart:17`) | identical to 1 | Category learning. Tolerates false merges; identity does not. |
| 4 | `normalizeMerchant` (`intelligence/text_normalizer.dart:74`) | Arabic-aware fold + lexicon stripping | Its own header forbids use as a persisted identity, and it is deliberately lossy for a fuzzy classifier. See "rules that are too aggressive" below. |
| 5 | `normalizeMerchant` (`supabase/functions/process-ios-sms/index.ts:1216`) | `toLowerCase().replace(/[^\p{L}\p{N}]+/gu,' ').trim()` | Server-side capture matching, different semantics again. |

1, 2 and 3 are Arabic-blind: `RegExp(r'[0-9]')` strips **ASCII digits only**, so
Arabic-Indic digits survive, and there is no hamza, teh-marbuta or diacritic
folding.

4 has two rules that are correct for a fuzzy classifier and **wrong for exact
identity**, both verified in source:

- `_leadingBoilerplate` (`text_normalizer.dart:23`) strips **bare single tokens**
  — `pos`, `purchase`, `payment`, `شراء`, `دفع` — so `PAYMENT SOLUTIONS` becomes
  `SOLUTIONS` and can match a different merchant called "Solutions".
- `_trailingNoise` (`text_normalizer.dart:33`) ends in `[0-9]*`, not `[0-9]+`, so
  the marker is stripped **with no identifier following it**: `CAFE TRACE` →
  `CAFE`, `X AUTH` → `X`.

---

## `merchant_alias_key_v1(text) → text` — NAMES

Applied in this exact order. Every step is a total function over the input.

### Step 1 — (no trim)
There is deliberately **no initial trim**. Dart's `String.trim()` and PostgreSQL's
`trim()` do not agree on which code points are whitespace, so a shared contract
cannot be built on either. Leading and trailing space is removed at step 8, after
step 6 has mapped every separator to a single ASCII `U+0020` — a set both
platforms handle identically.

Implementations MUST iterate **Unicode scalar values** (Dart: `runes`), never
UTF-16 code units.

### Step 2 — case fold, explicitly
Map `A`–`Z` (`U+0041`–`U+005A`) to `a`–`z` (`U+0061`–`U+007A`). **No other case
mapping is performed.** Arabic is caseless; every other script passes through
unchanged.

Platform `lower()` / `toLowerCase()` is deliberately NOT used: PostgreSQL's is
locale- and collation-dependent (Turkish `I` → `ı`, Greek final sigma), Dart's
follows the Unicode default casing table, and the two disagree on inputs a
merchant name can plausibly contain.

### Step 3 — remove diacritics and tatweel
Delete every code point in this set. It is written as ranges for readability;
**both implementations MUST enumerate it, never use a regex bracket range.**
PostgreSQL's documentation warns that bracket ranges are collating-sequence
dependent, and Dart's are code-point ordered — the two can disagree. The SQL
implementation uses `translate()` with an explicit character list, which has no
range semantics at all.

```
U+0610 … U+061A   Arabic signs
U+064B … U+065F   tanween, harakat, sukun, superscript marks
U+0670            Arabic letter superscript alef
U+0640            tatweel / kashida
```

34 code points total, enumerated in the implementations and in the fixtures.

### Step 4 — letter folds
An exhaustive one-to-one table. Nothing else is folded.

| From | | To | |
|---|---|---|---|
| `U+0623` | أ | `U+0627` | ا |
| `U+0625` | إ | `U+0627` | ا |
| `U+0622` | آ | `U+0627` | ا |
| `U+0671` | ٱ | `U+0627` | ا |
| `U+0629` | ة | `U+0647` | ه |
| `U+0649` | ى | `U+064A` | ي |
| `U+0624` | ؤ | `U+0648` | و |
| `U+0626` | ئ | `U+064A` | ي |
| `U+06A9` | ک | `U+0643` | ك |
| `U+06CC` | ی | `U+064A` | ي |

**`U+06AF` گ (gaf) is deliberately NOT folded**, unlike in
`text_normalizer.dart`. `ک` and `ی` are routine encoding variants of Arabic kaf
and yeh — folding them buys real recall on Saudi/Egyptian bank text. Gaf is a
distinct Persian phoneme with no Arabic equivalent, so folding it to `ك` buys no
recall in this market and only creates a collision: `گلستان` and `كلستان` would
share a key. A fuzzy classifier can afford that trade; an identity key cannot.

The remaining folds ARE lossy and that is an accepted, documented trade:
`ة→ه`, `ؤ→و` and `ئ→ي` collapse distinctions that two real merchants could in
principle rely on. They are kept because Egyptian and Gulf bank text writes these
interchangeably, so without them recall collapses in the primary market. The
residual risk is a WRONG match against an **uncatalogued** merchant whose name
folds onto a catalogued key — the unique index cannot see that collision, because
the other merchant has no row. Mitigation is alias review plus the ambiguity
blocklist, not the index.

### Step 5 — digit folds, digits RETAINED
`U+0660`–`U+0669` (Arabic-Indic) and `U+06F0`–`U+06F9` (Eastern Arabic-Indic)
map to `U+0030`–`U+0039`.

**Digits are then KEPT.** This is the single most important rule in the spec.
Stripping digits — as normalizers 1–3 do — produces stored, cross-user, permanent
false merges:

```
7-ELEVEN     → -ELEVEN     collides with a merchant named "Eleven"
360 MALL     → MALL        collides with any merchant named "Mall"
FOREVER 21   → FOREVER
CARREFOUR 24 → CARREFOUR
5 GUYS       → GUYS
STC 5G       → STC G
"123"        → ""          the empty key, which collides with everything
```

Branch numbers (`PANDA 123`) are handled by the **lookup pipeline**, not by the
key — see below. A miss is acceptable; a wrong merchant is not.

### Step 6 — everything outside the KEEP set becomes one ASCII space
The keep set is enumerated, not described by a Unicode category class — category
membership differs between Dart's and PostgreSQL's Unicode versions.

**KEEP exactly:**
```
U+0030 – U+0039   ASCII digits
U+0061 – U+007A   ASCII lowercase (all that survives step 2)
U+0621 – U+064A   Arabic letters hamza .. yeh
U+0671            alef wasla  (already folded at step 4; listed for closure)
U+06A9, U+06AF, U+06CC   Persian kaf/gaf/yeh (kaf+yeh folded at step 4; gaf kept)
```
Every other code point — Latin punctuation, Arabic punctuation (`U+060C` ،
`U+061B` ؛ `U+061F` ؟), symbols, control characters, every whitespace form
including `U+00A0`, `U+202F`, `U+3000`, `U+2000`–`U+200A`, and every invisible
format character `U+200B`–`U+200F`, `U+061C`, `U+FEFF` — maps to a single
`U+0020`.

**This step is why there is no initial trim.** Dart's `String.trim()` removes the
full Unicode White_Space set including `U+00A0`; PostgreSQL's `btrim(text)`
removes ASCII space only. A raw `"\u00A0CARREFOUR"` would key as `carrefour` in
Dart and `\u00A0carrefour` in PostgreSQL — a permanent, silent mismatch, and NBSP
is common in bank SMS. Routing every separator through step 6 first means step 8
only ever sees `U+0020`, which both platforms treat identically.

Neither implementation may use `\s`, `\p{…}`, `[[:space:]]` or `[[:punct:]]`.
Dart's `\s` is the fixed ECMAScript set; PostgreSQL's character classes are
ctype-dependent and vary across glibc/ICU versions, and its regex engine has no
`\p{}` at all.

### Step 7 — collapse whitespace
Replace every run of one or more `U+0020` with a single `U+0020`.

### Step 8 — trim again
Remove a leading or trailing `U+0020`.

### Result contract
- The output contains only `[a-z0-9]`, Arabic letters, and single interior spaces.
- **An empty result is not a key.** The server rejects it with a `CHECK`; the
  client abstains before lookup. Without this guard every input that folds away
  — all-punctuation, all-diacritic — shares one key.

### Deliberately absent: Unicode normalisation
No NFC/NFKC is applied. A decomposed form (`hamza` as a combining `U+0654`)
therefore keys differently from its precomposed form. This is a **deterministic
recall miss, not a reproducibility break** — both platforms miss identically —
and it is fixtured rather than fixed, because a shared NFKC contract would
require both runtimes to agree on a Unicode version, which they do not.

---

## `merchant_domain_key_v1(text) → text` — DOMAINS

A **separate** contract. Domains must never go through the name folder: digits,
dots and hyphens are semantically load-bearing, and `7eleven.com` folded as a
name would become `eleven.com`, a different company.

**The function takes an ALREADY-EXTRACTED HOST, not a URL.** URL parsing and
IDNA conversion happen upstream, on the client, before the key function is
called. This is deliberate: PostgreSQL core ships no URL parser and no IDNA
implementation that provably matches Dart's, and IDNA2008 vs UTS-46 disagree on
real inputs. Putting either inside the frozen contract would guarantee the drift
the whole design exists to prevent.

1. Map `A`–`Z` to `a`–`z` (ASCII only).
2. Drop a leading `www.`.
3. Drop a single trailing `.`.
4. Return empty (⇒ no key, caller abstains) unless the result matches
   `^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$`.

Only ASCII A-labels are stored and compared, `xn--` forms included. A Unicode
host is rejected rather than converted.

No other transformation. No digit folding, no separator collapsing, no label
removal beyond `www.`.

**Accepted risk:** dropping `www.` is technically lossy — DNS permits
`www.example.com` and `example.com` to resolve differently. It is conventional
and accepted here, and recorded as a decision rather than described as
identity-preserving.

---

## What is NOT in the key: `MerchantLookupPipeline.v1`

Lexicon-dependent cleanup is **query-side only** and lives outside both key
functions. This is a deliberate split.

A lexicon inside the key would mean every new acquirer prefix — a routine,
recurring event as banks change message formats — forces a full key-version
migration: new function, transactional re-key of every row, index rebuild, client
gating. Outside the key, the same change is a client lexicon update in the next
release, and it can only ever affect the **query string**, never stored identity.
A lexicon bug outside the key is shippable-fixable; the same bug baked into
stored keys is a data migration.

The completeness risk this creates — server and client disagreeing about what a
"clean" alias looks like — is closed at the write path instead: the database
**rejects** an `alias_raw` that still carries acquirer boilerplate, so a
boilerplate-bearing alias can never be stored and the mismatch cannot occur.

### Lookup order

1. `merchant_alias_key_v1(raw)` → exact lookup. **Unstripped first**, so an
   over-eager strip can never win over an exact catalogued alias.
2. On miss: strip anchored acquirer boilerplate and marker-introduced identifiers,
   then key and look up again.
3. On miss, if a merchant URL/domain is available: `merchant_domain_key_v1` → lookup.
4. Otherwise **ABSTAIN**.

### The write guard must be the MIRROR of this lexicon

Both reviewers independently found the same gap in the first draft: a guard that
rejects only *leading* boilerplate is asymmetric with a query stage that also
removes *trailing* markers. Concretely — catalog holds `CAFE TERM 4471` → merchant
A and `CAFE` → merchant B; a query for `CAFE TERM 4471` hits A unstripped, while
stripped-only would hit B. The system cannot call a suffix "noise" while
simultaneously permitting it inside a reviewed alias identity.

Therefore the database rejects an `alias_raw` matching **any** construct the
query stage can remove — leading wrappers AND marker-plus-digits tails.

The guard must also run on the **canonicalised** form, not on raw text. A raw
`\s`-based predicate is evadable: `POS-PURCHASE CARREFOUR` becomes
`pos purchase carrefour` after step 6 on the client but never matches a
whitespace-only server regex. The guard therefore applies steps 2–8 first, then
tests the lexicon.

Release ordering, because the guard and the client lexicon version independently:
**deploy the expanded server guard, validate existing aliases, then ship the
client lexicon.** The guard recognises the union of all still-supported client
pipeline versions. This is catalog validation, not a key migration — the key
function never changes.

### The stripping lexicon (step 2 only)

**Anchored multi-word wrappers only.** Never bare `pos`, `purchase`, `payment`,
`شراء`, `دفع`:

```
pos purchase      card purchase     purchase at
payment to        point of sale
شراء من           مشتريات من        عملية شراء        دفع الى
```

**Marker-introduced identifiers**, marker followed by `[0-9]+` — the `+` is the
correction to `text_normalizer.dart:36`'s `*`:

```
branch N   term N   terminal N   ref N   txn N   trace N   auth N
فرع N      ترمينال N   مرجع N
```

`PaymentAggregators.resolveMerchant` is **not** applied in this pipeline. It
already runs upstream at `add_transaction_usecase.dart:466`, and re-applying it
to arbitrary strings is ambiguous — its separator class includes plain whitespace
(`payment_aggregators.dart:18`), so a genuine merchant whose name begins with a
gateway token would be truncated.

---

## Country precedence

A country-scoped alias outranks a global alias **only when the country comes from
transaction, bank or card evidence.** Device locale and device location are not
evidence — a traveller or an expat would be silently mis-resolved.

**Issuer country is not merchant country.** Both reviewers flagged this as the
largest residual wrong-match path, and they are right: a KSA-issued card used in
Egypt or at a foreign online merchant yields "SA" evidence, which would select an
SA-scoped `CARREFOUR` over the correct row. Bank country, card-issuer country,
transaction currency, device locale and device location are **all** insufficient
on their own.

- Country scope activates **only** from evidence about the merchant's or
  acquirer's location.
- Country unknown → **global rows only**. Never guess.
- More than one candidate within the same tier → **abstain**.
- Candidates in different tiers pointing at different merchants, with no
  merchant-location evidence → **abstain**. The partial unique index scopes on
  `COALESCE(country_code,'')`, so `(alias,'SA')`→A and `(alias, global)`→B is a
  legal, intended pair; without evidence there is nothing to choose between them.

At Phase 1 the parser produces no merchant-location evidence, so the resolver
runs **global-only** in practice. The country path is implemented and tested but
is inert until such evidence exists. That is deliberate: shipping it live off
issuer country would be the exact wrong-match this section exists to prevent.

The admin panel warns when a new alias collides with an existing alias in a
different country tier, because after this rule the evidence quality is the only
thing between the user and a wrong merchant.

---

## Operational hazards for the migration runbook

- **`CREATE OR REPLACE FUNCTION` is NOT blocked by PostgreSQL** on a function used
  in a generation expression, and it does **not** recompute already-stored rows.
  Replacing a `_v1` body in place therefore yields silently stale keys with no
  error. The "never edit in place" rule is load-bearing, not stylistic.
- **`ALTER COLUMN … SET EXPRESSION` exists only in PostgreSQL 17.** On 15, a v2
  re-key means adding a new generated column, backfilling, and swapping — not an
  in-place expression change. The runbook must state which path the target
  version takes.
- **Generated columns are computed AFTER `BEFORE` triggers.** The boilerplate
  linter runs on `NEW.alias_raw` and cannot read `NEW.alias_normalized`. The
  empty-key `CHECK` on the generated column is fine — constraints are evaluated
  after generation.
- A lexicon held in a **table** requires a trigger, not a `CHECK`: `CHECK`
  constraints cannot contain subqueries.

## Related-code guard

`supabase/functions/process-ios-sms/index.ts:1216` exports a function also called
`normalizeMerchant`, with entirely different semantics. Catalog merchant matching
happens **on-device via `MerchantLookupPipeline.v1` only**. No server-side code
may resolve a catalog merchant, and that helper must never be wired to coupon or
interest logic.

## Testing contract

- `docs/coupons/merchant_alias_key_v1.fixtures.json` is the single shared corpus.
- A Dart test runs every fixture through the Dart implementation.
- A contract test runs every fixture through the **actual PostgreSQL function on
  a migrated database**. A JavaScript reimplementation would test nothing.
- Randomised differential tests cover the Arabic and Latin repertoire beyond the
  enumerated goldens, because golden cases only cover what someone thought of.
