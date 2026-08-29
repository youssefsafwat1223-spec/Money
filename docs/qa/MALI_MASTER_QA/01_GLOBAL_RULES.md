# 01 — Global Engineering Rules

These rules apply to every change in the Mali repository, regardless of layer (Flutter, Supabase, Edge Functions, iOS native, Android native). They formalize and extend the project's `CLAUDE.md` files. Where this document and a `CLAUDE.md` disagree, `CLAUDE.md` wins (see README.md "Source of truth hierarchy").

Related: [00_SYSTEM_PROMPT.md](00_SYSTEM_PROMPT.md), [22_CODING_STANDARDS.md](22_CODING_STANDARDS.md), [23_GIT_WORKFLOW.md](23_GIT_WORKFLOW.md).

## Rule 1 — Think before coding

Before implementing anything nontrivial:

- State your assumptions explicitly in writing (a PR description, a commit message, or a chat message).
- If multiple valid interpretations of a request exist, present them — do not silently pick one.
- If a simpler approach exists than the one requested, say so before building the complex one.
- If something is unclear, stop and name precisely what is unclear. Do not guess and proceed on financial-data logic.

**Why this matters for Mali specifically**: this is a personal finance app. A silently wrong assumption about transaction direction, currency handling, or duplicate detection produces wrong account balances for real users — not a cosmetic bug.

## Rule 2 — Simplicity first

- Ship the minimum code that solves the stated problem.
- No speculative abstractions for single-use code paths.
- No "configurability" that wasn't requested (e.g., don't add a new feature flag for something that isn't being gradually rolled out).
- No error handling for scenarios that structurally cannot happen (e.g., don't null-check a value the type system already guarantees is non-null).
- If a diff is 200 lines and could be 50, rewrite it before submitting.

**Test**: would a senior engineer reviewing this PR say "this is more than what was asked for"? If yes, cut it down.

## Rule 3 — Surgical changes

- Touch only what the task requires.
- Do not reformat, "clean up," or refactor adjacent code that isn't part of the task.
- Match existing style even when you'd personally do it differently.
- If you notice unrelated dead code or a pre-existing bug, **mention it in your report — do not fix it silently** unless it's a direct blocker for your task.
- Remove imports/variables/functions that *your own change* made unused. Do not remove pre-existing dead code unless asked.

**Test**: every changed line should trace directly to the task's stated goal. If you can't explain why a line changed, revert it.

## Rule 4 — Goal-driven execution

Transform vague tasks into verifiable goals before starting:

| Vague ask | Verifiable goal |
|---|---|
| "Add validation" | Write tests for invalid inputs, then make them pass |
| "Fix the bug" | Write a test that reproduces it, then make it pass |
| "Refactor X" | Ensure the existing test suite passes identically before and after |
| "Harden the notification pipeline" | Enumerate every race/duplicate scenario, write a regression test per scenario, then fix until all pass |

For any multi-step task, state a brief plan first:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

## Rule 5 — Financial correctness is non-negotiable

Specific to Mali's domain:

- Every money amount is `NUMERIC`/`double` with an explicit currency (`ISO 4217`, e.g. `SAR`, `AED`, `EGP`). Never assume a default currency in aggregation logic — always join through the account/transaction's own currency.
- Every date-range query for financial data uses **half-open intervals**: `>= from`, `< to`, never `<= to`. This avoids double-counting at month/day boundaries, especially across timezones (Riyadh/Cairo/Dubai are common user timezones and do not share a UTC offset).
- Transfer accounting must be applied consistently everywhere money direction is decided: an internal (own-account) transfer is neutral (excluded from income/expense totals); money sent to a third party is an expense; money received from a third party is income. This logic must never diverge between the local parser path, the AI parser path, and the backend relay path — see [09_DATA_FLOW.md](09_DATA_FLOW.md) §"Transfer accounting."
- Duplicate detection is not optional error handling — it is a core correctness requirement. See [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md) for every duplicate-detection layer and its failure modes.

## Rule 6 — Category keys are stable strings, not UUIDs

`'restaurants'`, `'subscriptions'`, `'transport'`, etc. are stable string keys shared between the Flutter app, the Supabase catalog, and Edge Function parsers. Local Drift storage uses local UUIDs as foreign keys to categories; Supabase storage uses the stable key directly. Any code that reads a Supabase-sourced transaction into the Flutter UI **must** translate key → local UUID before use — see [04_DATABASE.md](04_DATABASE.md) §"Category identity mismatch."

## Rule 7 — Feature flags use SHA-256, never `hashCode`

Dart's `Object.hashCode` is not guaranteed stable across Dart VM versions or app restarts for non-primitive-derived values in every context relevant here; the flag rollout bucket must be computed as `sha256("$installId:$flagKey")` truncated to a 16-bit int, `% 100`, compared against `rollout_percent`. This guarantees a user is deterministically bucketed across app updates and re-installs of the same device.

## Rule 8 — Migrations are additive and reversible by default

- Every migration in `supabase/migrations/` must have a matching rollback file in `supabase/rollback/`.
- Prefer additive changes (`ADD COLUMN ... NULL`, new tables) over destructive ones (`DROP COLUMN`, `ALTER ... NOT NULL` on existing data) whenever the task allows it.
- A migration that changes a constraint affecting existing rows must be verified against the *actual current row count and shape* of the live table before being written — do not assume a table's cardinality or nullability from the schema-only definition. See [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md).
- If a migration must be destructive, the rollback file must state explicitly what data loss (if any) is irrecoverable.

## Rule 9 — Gate commands are mandatory before every commit

From `app/CLAUDE.md`, run from the `app/` directory:

```bash
flutter analyze          # must be 0 issues
flutter test              # must pass, currently 500+ tests
flutter gen-l10n           # regenerate after any l10n change
```

Plus, for any change touching iOS native code:

```bash
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO
xcodebuild -workspace ios/Runner.xcworkspace -scheme BankMessageShortcuts -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO
```

Plus, for any change touching Edge Functions:

```bash
deno check <changed files>
deno test <changed test files>
```

See [10_TEST_STRATEGY.md](10_TEST_STRATEGY.md) for the complete gate matrix by change type.

## Rule 10 — Do not commit unless explicitly asked

Per `app/CLAUDE.md`: leave changes in the working tree for review unless the user explicitly says to commit. This applies doubly to AI agents — an AI committing code the user hasn't reviewed is a trust violation, not a convenience.

## Rule 11 — Arabic-first, RTL-correct

Mali's primary UI language is Arabic (RTL). Every user-facing string added must have both an `ar` and `en` ARB entry (see [06_FLUTTER.md](06_FLUTTER.md) §"l10n"). Notification copy, error messages, and empty states are not exempt — a hardcoded English string in a new feature is a defect, not a follow-up.

## Rule 12 — These rules work if...

...fewer unnecessary changes appear in diffs, fewer rewrites happen due to overcomplication, and clarifying questions come *before* implementation rather than after a mistake is shipped. If you notice the opposite pattern in your own work, stop and recalibrate against this document.
