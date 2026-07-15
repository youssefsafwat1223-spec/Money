# 07 — Security

Related: [03_ARCHITECTURE.md](03_ARCHITECTURE.md), [05_BACKEND.md](05_BACKEND.md), [25_DISASTER_RECOVERY.md](25_DISASTER_RECOVERY.md).

## 1. Threat model summary

| Asset | Threat | Mitigation |
|---|---|---|
| On-device transaction data | Device theft/loss, app-level data extraction | SQLCipher-encrypted Drift DB, key in Keychain/Keystore (not in the app binary, not in Drift itself), optional biometric app-lock gate |
| SMS content in transit to backend | Network interception, server-side log leakage | HTTPS to Edge Functions; PII sanitization (card/phone/account numbers redacted) **before** the SMS ever leaves the device; sanitized text only stored transiently for `needs_review`/`rejected` captures, 30-day retention |
| Capture relay tables | Cross-user data access via a compromised/guessed credential | Deny-all RLS on all four capture tables — reachable only via service-role Edge Functions, never any client credential |
| Financial tables (`user_*`) | Cross-user data access | RLS scoped to `auth.uid() = user_id` on every table, enforced at the Postgres level (defense-in-depth even if application code has a bug) |
| Device secret | Theft allowing capture-relay impersonation | Hashed at rest (`device_secret_hash`), never stored/transmitted in plaintext server-side, compared with a constant-time function to prevent timing attacks |
| Feature-flag override mechanism | Unauthorized global rollout enablement | Global `rollout_percent`/`is_active` changes require explicit human approval per [00_SYSTEM_PROMPT.md](00_SYSTEM_PROMPT.md); per-user overrides are scoped to one `user_id` and cannot affect other users |
| Service-role key | Client-side exposure would grant full DB access, bypassing all RLS | Lives only in Edge Function environment variables (`Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')`); **never** referenced in any Flutter/Dart client code, `--dart-define`, or committed file |

## 2. What is NOT the security model

Explicitly, per project history: **there is no HMAC secret embedded in the app binary.** The MVP security model for the capture pipeline is HTTPS transport + Edge Function device-secret filtering + deny-all RLS, not client-side request signing. This is a documented, deliberate tradeoff, not an oversight — do not "fix" it by adding client-embedded secrets without an explicit design discussion, since a secret embedded in a distributed app binary is extractable and provides limited real protection over the current model.

## 3. Encryption details

- **At rest (on-device)**: Drift database encrypted via `sqlite3mc` (SQLCipher-compatible). The encryption key is generated/retrieved via `DatabaseKeyStore`, persisted in `flutter_secure_storage` (Keychain on iOS, Keystore-backed on Android) — never in plaintext on disk, never in the database file itself, never logged.
- **At rest (Supabase)**: managed by Supabase's own infrastructure (Postgres at-rest encryption); the `backups` Storage bucket is private (no public URL access), gated by the same RLS-equivalent Storage policies from migration `0001_init.sql`.
- **In transit**: HTTPS everywhere — PostgREST, Edge Functions, GoTrue, APNs (mutual-TLS-equivalent via token auth), Storage.

## 4. PII handling rules

1. **SMS sanitization runs on-device before any network call.** Card numbers (`\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b` → `[CARD]`), phone numbers (Saudi/Egyptian mobile patterns + generic international → `[PHONE]`), and generic long account-number-shaped digit runs (`\b\d{10,20}\b` → `[ACCOUNT]`) are redacted by the same rule set on both the Swift (App Extension) and Deno (Edge Function, re-sanitizing defensively) sides.
2. **Merchant/beneficiary name handling**: real person names from transfers are never sent to the anonymous merchant-feedback queue (only POS/payment-type merchants are business names eligible for that queue) — see `AddTransactionUseCase` for the `isBusinessMerchant` gate.
3. **Logging discipline**: Edge Function logs are structured JSON containing only booleans/enums/counts (`hasAmount`, `confidence`, `parserSource`) — **never** raw SMS text, merchant strings, phone/card numbers, or secrets. Any new log line added to a capture-pipeline function must be reviewed against this rule before merge.
4. **Notification content**: transaction amount/merchant/category may appear in a push notification body (visible on a lock screen) — this is an accepted, user-facing tradeoff (the whole point of the feature), but **account balance is never shown** in any notification, specifically to limit lock-screen exposure.

## 5. Authentication & session security

- Sign-in is Google Sign-In or Sign in with Apple only — no password-based auth for end users (reduces credential-stuffing/phishing surface).
- The admin panel is the only surface with email/password auth, and has **no self-serve sign-up** — accounts are provisioned manually in the Supabase dashboard.
- JWTs are managed entirely by `supabase_flutter`'s own session handling; the app does not implement custom token storage/refresh logic.
- Optional biometric app-lock (`local_auth`) gates app foreground access independently of the backend session — this protects the on-device Drift data even when the device itself is unlocked but handed to someone else temporarily.

## 6. Debug-only test seams — a standing risk category

This codebase has, at times, used `kDebugMode`-gated test seams (e.g., a `QA_REFRESH_TOKEN` dart-define to inject a session via `Supabase.instance.client.auth.setSession()` for QA without a full OAuth flow). Rules for these:

- Must be `kDebugMode`-gated (compiled out of release builds) or explicitly removed before any release.
- Must never read from a value that could plausibly be set in a production build config.
- Must be tracked explicitly as a cleanup item — see [17_BUG_WORKFLOW.md](17_BUG_WORKFLOW.md) and [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md) pre-release checklist — a debug seam left in past its usefulness is a latent security smell even if currently harmless.

## 7. Third-party data processors

| Processor | Data sent | Purpose | Gate |
|---|---|---|---|
| Google Gemini (AI parse) | Sanitized SMS text only (PII already redacted) | Backup/enhancement to deterministic parsing | `allowAi` flag, sourced from on-device `ai_consent_granted` — **opt-in**, defaults to off |
| Google Places (`enrich-merchant`) | Merchant name string only | Category resolution for unknown merchants | Requires the same AI/enrichment consent gate |
| Apple APNs | Notification title/body (already category-safe per §4) + payload IDs | Push delivery | N/A — required for the feature to function at all |
| Sentry | Stack traces, breadcrumbs | Crash/error reporting | `SentryConfig.isConfigured` — optional at build time |

**Never** send raw (unsanitized) SMS text to any third-party API. The sanitize-then-send ordering in `process-ios-sms` (`reSanitize()` applied server-side even though the client already sanitized) is defense-in-depth against a client-side sanitization bug — preserve both layers.

## 8. Security review checklist for new capture/notification code

Before merging any change to the capture or notification pipeline, confirm:

- [ ] No new log line contains raw SMS text, a full phone/card/account number, or a secret.
- [ ] Any new Edge Function endpoint enforces device-secret or JWT auth — no unauthenticated financial-data-adjacent endpoint.
- [ ] Any new table default-denies RLS unless it is intentionally a per-user-scoped table with an explicit `auth.uid() = user_id` policy.
- [ ] No service-role key reference appears anywhere under `app/lib/`.
- [ ] Any new AI/third-party call is gated by the existing consent flag, not a new ungated one.
- [ ] Notification content still excludes account balance.

See also: [21_CHECKLISTS.md](21_CHECKLISTS.md) for the consolidated checklist set, and `security-review` skill for an automated pass over a diff.
