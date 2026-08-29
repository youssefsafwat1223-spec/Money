# 02 — Project Discovery

Related: [03_ARCHITECTURE.md](03_ARCHITECTURE.md), [08_FEATURES.md](08_FEATURES.md).

## 1. What Mali is

Mali (Arabic name: قرش / "Qirsh", meaning "penny/piastre") is a mobile expense-tracking app whose defining feature is **automatic transaction capture from bank SMS messages**, with zero manual data entry required for the common case. It targets Arabic-speaking users in the Gulf/MENA region (Saudi Arabia, UAE, Egypt, Qatar, Oman, Kuwait, Bahrain, Jordan primarily, based on supported currencies: SAR, AED, EGP, QAR, OMR, KWD, BHD, JOD, plus USD/EUR/GBP for foreign transactions).

- **Platform**: Flutter (iOS + Android), package name `money_companion`.
- **Bundle ID**: `com.youssefsafwat.mali` (iOS).
- **Primary language**: Arabic (RTL), with English support.
- **Core promise**: "Send us your bank SMS, we categorize your spending automatically" — no manual bookkeeping.

## 2. The problem Mali solves

Manual expense trackers fail because users stop entering transactions after a few days. Mali's approach: intercept the bank's own SMS notification (which already fires for every card transaction, deposit, and withdrawal in the target markets) and parse it automatically into a categorized transaction, on-device, with no manual step for the common case.

## 3. Core user journeys

1. **Onboarding**: user installs the app, sets up biometric lock (optional), picks a base currency/country, and — critically — sets up either Android SMS permission (direct SMS read) or an iOS Shortcuts automation (since iOS does not allow apps to read SMS directly).
2. **Passive capture**: a bank SMS arrives → it is parsed (on-device on Android via direct SMS access, or via a Shortcuts automation + backend relay on iOS) → a transaction appears in the app, usually already categorized and confirmed, occasionally flagged for the user to confirm (low confidence) or review (suspected duplicate).
3. **Active review**: user opens the app, sees a chronological transaction list, dashboard totals by account/currency, category breakdowns, and can edit/delete/recategorize any transaction.
4. **Planning**: user sets budgets (per category or all-expenses), savings goals with contributions, tracks recurring subscriptions/bills, and views spend reports/charts.
5. **Multi-currency, multi-account**: users with multiple bank accounts/cards in different currencies see per-account and per-currency totals without manual FX conversion (FX conversion is an explicit non-goal today).

## 4. Why iOS and Android differ structurally

- **Android**: apps can request `READ_SMS`/`RECEIVE_SMS` permission and parse messages directly and immediately, fully on-device, no backend involvement required for the base case.
- **iOS**: Apple does not allow any app to read the SMS inbox. Mali works around this using **Shortcuts automations** — the user configures an iOS Automation that triggers on a message matching bank keywords, which invokes Mali's **App Intent** ("Process Bank SMS"), running in a small App Extension (`BankMessageShortcuts`) independent of the main app process. This extension can optionally call a backend relay (`process-ios-sms` Edge Function) for parsing, then hands the result back as a local/push notification and a durable relay row that the main app imports next time it's opened. See [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md) for the complete mechanics.

## 5. Architectural philosophy: local-first, migrating to backend-primary

Mali began as a fully **on-device** app: an encrypted local Drift (SQLite via SQLCipher) database was the single source of truth, with Supabase used only for catalog data (bank profiles, parser rules, categories, feature flags) — never for financial data.

The project is now (as of this handbook's writing) in an active, **gradual, flag-gated migration** to a **Supabase-primary** architecture for financial entities (accounts, transactions, budgets, goals, subscriptions, plans, smart inbox), because:

- Multi-device sync was impossible with a fully local-only model.
- Server-side aggregation (dashboard summaries, reports) scales better than repeated on-device SQL over a growing dataset.
- A durable server-side capture relay (`processed_captures`) is necessary for the iOS Shortcuts flow to work reliably regardless of when the user next opens the app.

This migration is executed **per financial entity**, **per user**, gated by feature flags (`accounts_supabase_primary`, `transactions_supabase_primary`, `budgets_supabase_primary`, `goals_supabase_primary`, `subscriptions_supabase_primary`, `plans_supabase_primary`, `smart_inbox_supabase_primary`, `capture_direct_supabase_write`), all defaulting to **OFF globally**, testable per-user via `feature_flag_overrides`. See [03_ARCHITECTURE.md](03_ARCHITECTURE.md) §"Supabase-primary migration model" for the full mechanics, and [30_ROADMAP.md](30_ROADMAP.md) for the phase plan.

## 6. Key non-goals (as of this handbook)

- **No FX conversion**: multi-currency totals are shown per-currency, not converted to a single base currency.
- **No manual bank linking (Open Banking/Plaid-style)**: Mali never has read access to a bank account or balance directly; it only ever sees what the bank's own SMS notification contains.
- **No server-side SMS storage as the norm**: raw SMS text is sanitized (card numbers, phone numbers, account numbers redacted) before ever leaving the device, and server-stored raw text is only retained transiently for `needs_review`/`rejected` captures, subject to a 30-day retention policy.
- **No cross-user social features.**

## 7. Repository layout (top level)

```
Money/                              # monorepo root
├── app/                            # Flutter application (this handbook's primary subject)
├── supabase/                       # Supabase project: migrations, Edge Functions, rollback scripts
├── admin/                          # Next.js 14 admin panel (catalog/flags/announcements management)
├── docs/                           # historical planning docs (architecture decisions, retirement plans)
├── MALI_MASTER_QA/                 # this handbook
└── CLAUDE.md                       # root-level behavioral guidelines for AI coding agents
```

See [03_ARCHITECTURE.md](03_ARCHITECTURE.md) for the full breakdown of `app/lib/`.

## 8. Who maintains this

At the time of this handbook, Mali is maintained by a small (effectively solo) engineering effort, augmented heavily by AI coding agents (Claude Code) operating under the constraints in [00_SYSTEM_PROMPT.md](00_SYSTEM_PROMPT.md) and [01_GLOBAL_RULES.md](01_GLOBAL_RULES.md). This has direct process implications:

- There is no separate QA team — QA is executed by the same agent/engineer who wrote the change, using dedicated QA identities against the live Supabase project (there is no separate staging database).
- Documentation (this handbook included) is the primary mechanism for preserving context across sessions, since there is no large standing team carrying institutional knowledge.
- Release decisions, flag rollouts, and production actions require explicit human sign-off at each step — see [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md) and [28_PRODUCTION_RUNBOOK.md](28_PRODUCTION_RUNBOOK.md).
