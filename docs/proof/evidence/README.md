# Proof-Carrying — preserved reproducibility evidence

The research lab that produced the Proof-Carrying result lives in `research/`,
which is **deliberately not version-controlled** (2.0 GB — a 1.1 GB virtualenv,
303 MB of external datasets, 96 MB of model weights). It is not a build input:
the only references to it anywhere in `app/` or `supabase/` are prose in two
test comments.

More importantly, `research/sms_model_lab/data/` holds `holdout_real.jsonl` —
**real bank SMS contributed for evaluation**. That must never become a
repository fixture. Ignoring the whole tree in `.gitignore` is the mechanism
that guarantees it, rather than relying on everyone remembering.

The four small artifacts below are the ones a future reader actually needs to
verify the frozen result. They are copied here so they survive in version
control without the corpus.

| File | What it is |
|---|---|
| `phase4_frozen_v7_1.seal` | The Rev 7.1 contract seal, `ba3792f5f665049edcb8c2290f19ada0638325d6ef95c55f659b87e6917d18bc`. Rev 7.1 changed only the Gemini response schema: `transaction_amount` and `currency` became structurally required while remaining nullable, so a model that cannot resolve a field must return an explicit `null` rather than omit the key. An explicit null still resolves to REVIEW; no deterministic authority was weakened. |
| `gemini_phase5_gate.json` | The Phase-5 gate result under Rev 7.1 — verdict, per-split metrics, failure counts, and the deterministic mask hash the run was sealed against. Metrics only; contains no message text. |
| `catalog_rules.json` | The D3 deterministic catalog rules, mechanically extracted from `supabase/migrations/0002_catalog_mvp.sql`. Carries its own `_source` / `_generator` / `_why` provenance keys. The Arabic in this file is catalog keyword content from that committed migration, not user data. |
| `extract_catalog_rules.py` | The generator for the file above. Deterministic and byte-reproducible, so the rules can be regenerated from the migration and diffed rather than trusted. |

## What is deliberately NOT here

Corpora (`train`/`val`/`holdout_syn`/`hard`/`finee`), model weights, run logs,
per-model result files, and the virtualenv. All are reproducible from the lab or
are evaluation data that should not leave it.

**Metric C / "provable coverage" in the gate file is model parity on rows the
deterministic architecture could already prove — it is not end-to-end
auto-commit coverage.** Honest end-to-end coverage is substantially lower
because the architecture deliberately routes cases to REVIEW. Do not quote it as
a real-world auto-commit percentage.
