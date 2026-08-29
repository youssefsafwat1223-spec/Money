# Primary AI — On-Device Classifier

Canonical: `app/lib/engine/intelligence/merchant_classifier.dart`
Persistence: `merchant_intelligence_store.dart`

## What it is

A TF-IDF character n-gram nearest-neighbour classifier, pure Dart, trained on the
~330-pair merchant→category catalog the app already ships.

## Why this and not a neural model

The measured labelled corpus is ~37 examples and is contaminated by a prior
parser defect (F-015). That is too small to train on and — decisively — **too
small to evaluate with**, so a shipped neural model's accuracy could not be
stated, let alone defended. Consent is off-by-default and fail-closed, so no
corpus-collection pipeline exists that would change that.

Read correctly this is not a consolation prize: a character n-gram model is the
**right** tool for short, noisy, transliterated merchant strings, which is a
character-level entity-matching problem rather than a sentence-semantics one.

## Cost profile — this is why it satisfies OD-13

| Dimension | Value |
|---|---|
| Per-request cost | **zero** |
| Network | **none** |
| Model asset | **none** |
| Native dependency | **none** |
| Latency | well under 1 ms |
| Battery / app size | no story to defend |

## The write fence (OD-11, OD-13)

The model may influence exactly two things: a suggested **category** and a
normalised merchant **display name**.

It must never touch: amount, currency, direction, date, account identity, card
identity, balances, any canonical `_minor` money field, or dedup/identity/sync
keys. `normalizedMerchant` is a matching key and a display candidate — never a
join key, never a persisted identity.

## Abstention is the product promise

Below the confidence floor it returns `null` rather than guessing. The promise is
**precision when it speaks, not coverage**.

## Learning

`MerchantIntelligenceStore` persists corrections so the model improves with use.
An earlier defect constructed the classifier twice per transaction (~8.6 ms of
fitting for ~0.3 ms of prediction, with no instance outliving the call, so
learning was discarded). Fixed via the store plus `merchantIntelligenceProvider`.

## Verification

`app/test/domain/usecases/correct_category_learns_test.dart` ·
`app/test/engine/merchant_intelligence_eval_test.dart`

**This path needs no key, no network and no consent. It is the normal path.**
