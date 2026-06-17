# Bank Discovery Implementation Plan

## 0. Executive Summary

Bank Discovery lets Mali identify an unknown SMS sender as a likely bank using Gemini, then asks the user to confirm the mapping once. After confirmation, Mali stores a sender-to-bank mapping locally and syncs it to Supabase. Future SMS messages from that sender must resolve from the local mapping and skip Gemini completely.

This system must not create banks automatically, must not raise transaction trust based on Gemini alone, and must not auto-save transactions from an unsupported or untrusted parser profile. Gemini is only an identity suggestion layer.

## 1. Current Architecture Review

Current relevant components:

- `ParserEngine`: pure Dart rule-based parser. It detects `BankProfile`, extracts amount/currency/merchant/balance/date, and caps generic parser confidence at `0.79`.
- `BankProfiles.detect`: matches sender/text against built-in and catalog-provided `BankProfile` data.
- `ParserIsolate`: wraps `ParserEngine` in an isolate with timeout.
- `AddTransactionUseCase`: orchestrates parsing, dedup, categorization, AI parser fallback, persistence, and pending/confirmed status.
- `Categorizer`: maps parsed transaction to category with confidence.
- Drift local DB: app storage layer for transactions, categories, catalog tables, settings, and sync metadata.
- Catalog system: `remote_banks`, `remote_parsers`, countries, currencies, categories, feature flags, announcements.
- AI parser infrastructure: `AiParserClient`, `SmsSanitizer`, grounding checks, consent checks, and AI failure suppression.
- Supabase: backend for production data, catalog, user profiles, backup/sync-like flows, and RLS-protected tables.

Important existing safety behavior:

- Generic parser can produce pending-level results but cannot auto-confirm.
- AI-parsed transactions are capped and must remain pending.
- OTP/promo/admin ignore filters should exit early.
- Raw SMS should not leave the device except through explicitly sanitized AI flows.

Bank Discovery should be a new layer between sender/profile resolution and transaction parsing/AI parsing. It must be separate from transaction parsing AI.

## 2. Files That Will Be Modified

Planned new files:

- `app/lib/domain/entities/sender_bank_mapping_entity.dart`
- `app/lib/domain/entities/bank_discovery_suggestion.dart`
- `app/lib/domain/repositories/sender_bank_mapping_repository.dart`
- `app/lib/domain/usecases/resolve_bank_for_sender_usecase.dart`
- `app/lib/domain/usecases/confirm_bank_discovery_usecase.dart`
- `app/lib/domain/usecases/reject_bank_discovery_usecase.dart`
- `app/lib/engine/ai/bank_discovery_client.dart`
- `app/lib/engine/ai/gemini_bank_discovery_client.dart`
- `app/lib/engine/privacy/bank_discovery_sanitizer.dart`
- `app/lib/data/repositories/drift_sender_bank_mapping_repository.dart`
- `app/lib/data/sync/sender_bank_mapping_sync_service.dart`
- `app/lib/features/bank_discovery/bank_discovery_controller.dart`
- `app/lib/features/bank_discovery/bank_discovery_confirmation_sheet.dart`
- `app/lib/features/settings/bank_mappings_screen.dart`
- `app/test/engine/bank_discovery_client_test.dart`
- `app/test/domain/bank_discovery_usecase_test.dart`
- `app/test/data/sender_bank_mapping_repository_test.dart`
- `app/test/features/bank_discovery/bank_discovery_confirmation_sheet_test.dart`

Planned existing files to modify:

- `app/lib/data/db/app_database.dart`
- `app/lib/core/di/app_providers.dart`
- `app/lib/domain/usecases/add_transaction_usecase.dart`
- `app/lib/engine/parser/parser_isolate.dart` only if sender resolution is injected there; preferred is to avoid this.
- `app/lib/engine/parser/bank_profile.dart` only for helper lookup by `bankKey`; no Gemini-created profiles.
- `app/lib/features/app/app_shell.dart` or capture flow component that opens pending confirmation UI.
- `app/lib/features/settings/settings_screen.dart`
- `supabase/migrations/<new>_sender_bank_mappings.sql`

Files that should not be changed for Phase 1:

- Parser confidence thresholds.
- OTP/promo/security ignore rules except if adding explicit admin notice filters.
- Transaction auto-confirm thresholds.
- Remote catalog behavior.

## 3. Database Changes

Add a local Drift table for confirmed/rejected/pending sender-bank mappings.

Add a Supabase table for per-user synced mappings.

No table should store raw SMS. The only SMS-derived fields allowed are:

- normalized sender ID
- suggested bank name
- country
- confidence
- status
- optional bank key if it matches an existing trusted catalog/built-in bank
- timestamps and sync metadata

## 4. Drift Table Design

Proposed local table:

```sql
CREATE TABLE sender_bank_mappings (
  id TEXT PRIMARY KEY,
  sender_id TEXT NOT NULL,
  normalized_sender_id TEXT NOT NULL UNIQUE,
  bank_key TEXT NULL,
  suggested_bank_name TEXT NOT NULL,
  suggested_country TEXT NOT NULL,
  confidence REAL NOT NULL,
  status TEXT NOT NULL,
  source TEXT NOT NULL,
  first_seen_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  confirmed_at TEXT NULL,
  rejected_at TEXT NULL,
  rejection_expires_at TEXT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  synced_at TEXT NULL,
  sync_status TEXT NOT NULL DEFAULT 'pending'
);
```

Allowed `status`:

- `pending`: suggestion was created but user has not answered.
- `confirmed`: user confirmed the mapping.
- `rejected`: user rejected the suggestion.

Allowed `source`:

- `gemini`
- `user_manual`
- `remote`

Allowed `sync_status`:

- `pending`
- `synced`
- `failed`

Indexes:

```sql
CREATE UNIQUE INDEX idx_sender_bank_mappings_normalized_sender
ON sender_bank_mappings(normalized_sender_id);

CREATE INDEX idx_sender_bank_mappings_status
ON sender_bank_mappings(status);

CREATE INDEX idx_sender_bank_mappings_sync_status
ON sender_bank_mappings(sync_status);
```

Important constraints:

- `normalized_sender_id` must be unique locally.
- `confidence` must be between `0` and `1`.
- `status = confirmed` requires `confirmed_at IS NOT NULL`.
- `status = rejected` requires `rejected_at IS NOT NULL`.

## 5. Repository Design

Create `SenderBankMappingRepository`.

Interface:

```dart
abstract class SenderBankMappingRepository {
  Future<SenderBankMappingEntity?> getBySender(String senderId);

  Future<SenderBankMappingEntity?> getConfirmedBySender(String senderId);

  Future<SenderBankMappingEntity?> getActiveSuggestionBySender(String senderId);

  Future<void> saveSuggestion({
    required String senderId,
    required BankDiscoverySuggestion suggestion,
  });

  Future<SenderBankMappingEntity> confirm({
    required String mappingId,
    String? bankKey,
  });

  Future<SenderBankMappingEntity> reject({
    required String mappingId,
    Duration cooldown,
  });

  Future<List<SenderBankMappingEntity>> getAll();

  Future<List<SenderBankMappingEntity>> pendingSync();

  Future<void> markSynced(String id);

  Future<void> markSyncFailed(String id);

  Future<void> delete(String id);
}
```

Implementation:

- `DriftSenderBankMappingRepository`
- Normalizes sender IDs before lookup.
- Never writes raw SMS.
- Uses upsert semantics for repeated Gemini suggestions.
- Does not overwrite `confirmed` mappings with later Gemini suggestions.
- Does not show rejected mapping again until `rejection_expires_at` has passed.

## 6. Service Design

Create `BankDiscoveryService`.

Responsibilities:

- Decide if bank discovery is eligible.
- Check local confirmed mapping before Gemini.
- Call Gemini bank discovery only when necessary.
- Store high-confidence suggestions as pending.
- Tell UI that a confirmation sheet should be shown.
- Never create or trust a bank automatically.

Suggested API:

```dart
class BankDiscoveryService {
  Future<BankResolution> resolve({
    required String rawSms,
    required String? senderId,
    required List<BankProfile> availableProfiles,
  });
}
```

Return model:

```dart
sealed class BankResolution {}

class BankResolutionMatchedProfile extends BankResolution {
  final BankProfile profile;
}

class BankResolutionConfirmedMapping extends BankResolution {
  final SenderBankMappingEntity mapping;
  final BankProfile? profile;
}

class BankResolutionNeedsUserConfirmation extends BankResolution {
  final SenderBankMappingEntity pendingMapping;
}

class BankResolutionUnknown extends BankResolution {}
```

Eligibility:

- `senderId` is not null/empty.
- Sender is likely bank-like using `BankSenderFilter`.
- `BankProfiles.detect` returned null.
- No local confirmed mapping exists.
- No active rejected mapping exists inside cooldown.
- Message is not ignored by rule-based ignore filters.
- User has AI consent enabled.
- Rate limit allows discovery.

## 7. Gemini Bank Discovery Client Design

Create `BankDiscoveryClient`.

```dart
abstract class BankDiscoveryClient {
  Future<BankDiscoverySuggestion?> detectBank({
    required String senderId,
    required String sanitizedSms,
    String? currencyHint,
    String? countryHint,
    required String installId,
  });
}
```

Gemini implementation:

- `GeminiBankDiscoveryClient`
- Reuses existing AI config style.
- Must use a strict JSON schema response.
- Must timeout quickly, e.g. 4 seconds.
- Must return null on malformed JSON.
- Must never throw into the capture pipeline.

Response:

```dart
class BankDiscoverySuggestion {
  final String bankName;
  final String? bankKeySuggestion;
  final String country;
  final double confidence;
  final String reason;
}
```

Prompt rules:

- Identify only the bank/institution behind the sender and SMS format.
- Do not parse transaction details.
- Do not infer user identity.
- Return confidence as `0.0` to `1.0`.
- If uncertain, return confidence below `0.95`.

Example expected response:

```json
{
  "bankName": "Abu Dhabi Islamic Bank",
  "bankKeySuggestion": "adib_ae",
  "country": "AE",
  "confidence": 0.97,
  "reason": "Sender ADIB and AED account wording match UAE ADIB alerts"
}
```

## 8. Confirmation Bottom Sheet UX

Trigger:

- Show only when Gemini confidence is `>= 0.95`.
- Show once per sender until user chooses.
- Do not block transaction confirmation flow; if both transaction confirmation and bank discovery are needed, show transaction confirmation first, then bank discovery as a lighter follow-up, or queue the bank sheet for next app frame.

Copy:

Title:

```text
We think this is Abu Dhabi Islamic Bank
```

Body:

```text
Sender: ADIB
Country: United Arab Emirates
Confidence: 97%

Confirming helps Mali recognize future messages from this sender without using AI again.
```

Actions:

- Primary: `Yes, this is ADIB`
- Secondary: `Not this bank`
- Tertiary: `Ask me later`

Behavior:

- Confirm:
  - Saves local mapping as `confirmed`.
  - Syncs to Supabase.
  - Future messages bypass Gemini.
- Reject:
  - Saves local mapping as `rejected`.
  - Applies cooldown, e.g. 30 days.
- Ask me later:
  - Keeps mapping `pending`.
  - Does not call Gemini again immediately.
  - Can show again after a short cooldown, e.g. 7 days.

UX placement:

- New feature folder: `features/bank_discovery`.
- Called from app shell/capture flow after message ingestion.
- Keep RTL/localization support.

## 9. Supabase Sync Design

Supabase table:

```sql
CREATE TABLE user_sender_bank_mappings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  normalized_sender_id text NOT NULL,
  bank_key text NULL,
  suggested_bank_name text NOT NULL,
  suggested_country text NOT NULL,
  confidence numeric NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
  status text NOT NULL CHECK (status IN ('confirmed', 'rejected')),
  source text NOT NULL CHECK (source IN ('gemini', 'user_manual', 'remote')),
  confirmed_at timestamptz NULL,
  rejected_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, normalized_sender_id)
);
```

Sync direction for MVP:

- Local to remote only for confirmed/rejected mappings.
- Remote to local on login/app start, so a user’s mappings follow them across devices.

Conflict rules:

- Confirmed beats pending.
- Latest user action wins between confirmed/rejected.
- Remote must not overwrite a newer local `updated_at`.

No raw SMS should be synced.

## 10. RLS Policies

Enable RLS:

```sql
ALTER TABLE user_sender_bank_mappings ENABLE ROW LEVEL SECURITY;
```

Policies:

```sql
CREATE POLICY "Users can select own sender bank mappings"
ON user_sender_bank_mappings
FOR SELECT
USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own sender bank mappings"
ON user_sender_bank_mappings
FOR INSERT
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own sender bank mappings"
ON user_sender_bank_mappings
FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own sender bank mappings"
ON user_sender_bank_mappings
FOR DELETE
USING (auth.uid() = user_id);
```

Server-side safeguards:

- Do not allow anonymous global reads.
- Do not add a public bank mapping table in MVP.
- Optional later: aggregate anonymous discovery stats through an Edge Function only, with no raw sender IDs and no SMS text.

## 11. Settings Screen For Managing Mappings

Add `Bank Sender Mappings` under Settings privacy/data or advanced section.

Screen content:

- List confirmed mappings:
  - Sender ID
  - Bank name
  - Country
  - Last seen
  - Sync status
- List rejected mappings:
  - Sender ID
  - Suggested bank
  - Rejection expiry
- Actions:
  - Delete mapping
  - Change bank manually, later phase
  - Re-enable suggestion, later phase

Important UX:

- Explain that deleting a mapping may make Mali ask again or use Gemini again if AI consent is enabled.
- No raw SMS previews.

## 12. Exact Parser Pipeline Changes

Current simplified flow:

```text
raw SMS
→ ParserIsolate / ParserEngine
→ BankProfiles.detect
→ parse result
→ categorizer
→ optional AI parser fallback
→ save transaction pending/confirmed
```

Proposed flow:

```text
raw SMS
→ normalize sender
→ ignore/admin/OTP/promo pre-check
→ load local sender-bank mapping
→ if confirmed mapping exists:
     resolve profile by bank_key if available
     skip Gemini
→ else:
     run BankProfiles.detect
→ if no profile and no mapping:
     run generic parser
     if discovery eligible:
        call Gemini bank discovery
        if confidence >= 0.95:
           store pending suggestion
           request confirmation sheet
→ parse transaction using trusted profile if available, else generic
→ generic/AI results remain pending
```

Implementation detail:

- Do not put discovery inside `ParserEngine`; keep `ParserEngine` pure and deterministic.
- `AddTransactionUseCase` can orchestrate discovery, but better long-term is a wrapper use case:
  - `IngestCapturedMessageUseCase`
  - calls `BankDiscoveryService`
  - then calls `AddTransactionUseCase`
- For MVP, minimal change may inject `BankDiscoveryService` into `AddTransactionUseCase`, but avoid making it too large.

Critical behavior:

- Confirmed sender mapping can choose a known bank profile if `bankKey` maps to a built-in/catalog profile.
- If no trusted profile exists, use generic parser only.
- Confirmed mapping must not increase confidence by itself.
- If profile exists but has no golden coverage for auto-confirm, transaction remains pending.

## 13. Tests Required

Unit tests:

- Unknown sender, no mapping, Gemini confidence `0.97` → pending mapping stored, confirmation requested.
- Unknown sender, Gemini confidence `0.94` → no mapping shown.
- Unknown sender, Gemini returns malformed JSON → ignored gracefully.
- User confirms mapping → local status becomes `confirmed`.
- User rejects mapping → local status becomes `rejected`, cooldown set.
- Confirmed mapping exists → Gemini client call count is `0`.
- Rejected mapping inside cooldown → Gemini client call count is `0`.
- Mapping to unknown bank key → generic parser pending only.
- Mapping to known bank key → profile is passed to parser.
- Admin/OTP/promo ignored message → discovery not called.
- AI consent off → discovery not called.
- Sender is personal phone number → discovery not called.

Repository tests:

- Upsert pending suggestion.
- Confirm pending suggestion.
- Reject pending suggestion.
- Unique sender normalization.
- Pending sync query.
- Mark synced/failed.
- Delete mapping.

Supabase sync tests:

- Push confirmed mapping.
- Pull remote mapping.
- Conflict latest update wins.
- No raw SMS fields exist in payload.

Widget tests:

- Confirmation sheet renders bank/country/confidence.
- Confirm button calls confirm use case.
- Reject button calls reject use case.
- Ask later dismisses without confirming.
- RTL layout.

Regression tests:

- ADIB chequebook admin notice stays ignored.
- ADIB AED transaction generic parses to pending and no AI parser call is made once generic succeeds.
- Future ADIB sender after confirmed mapping skips Gemini bank discovery.

## 14. Privacy And Security Risks

Risks:

- Sending raw SMS to Gemini could leak financial/personal data.
- Gemini could hallucinate a bank name.
- Auto-creating banks from Gemini could poison parser behavior.
- Global mappings could leak user-bank relationships.
- Sender IDs can be sensitive.

Mitigations:

- Use sanitized SMS for discovery.
- Send only one sample and sender ID.
- Require user confirmation.
- Store per-user mapping only.
- Never auto-create global banks.
- Never auto-confirm transactions from Gemini identity suggestion.
- Keep discovery separate from transaction parsing AI.
- Add rate limits and cooldowns.
- Provide delete mapping in Settings.
- Do not store raw SMS in Supabase.

## 15. Rollout Phases

### Phase 1 — Local Foundation

- Add Drift table and repository.
- Add mapping lookup before Gemini.
- Add confirmation/rejection use cases.
- Add tests.

No Gemini call yet.

### Phase 2 — Gemini Discovery Behind Flag

- Add `BankDiscoveryClient`.
- Add Gemini implementation.
- Add strict JSON parsing.
- Add confidence threshold `>= 0.95`.
- Add local pending suggestion storage.
- Feature flag default off.

### Phase 3 — Confirmation UX

- Add bottom sheet.
- Wire to capture/app shell flow.
- Confirm/reject/ask later behavior.
- Add settings entry.

### Phase 4 — Supabase Sync

- Add migration.
- Add RLS.
- Add sync service.
- Pull on login/app start.
- Push local confirmed/rejected changes.

### Phase 5 — Management And Observability

- Full Settings screen.
- Local-only diagnostics.
- Optional anonymized aggregate discovery metrics later.

## 16. Migration Strategy

Local:

- Increment Drift schema version.
- Create `sender_bank_mappings`.
- Add indexes.
- No backfill required.

Remote:

- Add Supabase migration.
- Enable RLS.
- Add policies.
- No global catalog changes.

Backward compatibility:

- Existing users have no mappings.
- Pipeline falls back to current behavior.
- If migration fails locally, disable discovery and continue parsing normally.

## 17. Failure Handling

Gemini timeout:

- Continue normal generic parser flow.
- No user sheet.

Gemini low confidence:

- No sheet.
- Optional local diagnostic only.

Malformed Gemini response:

- Treat as null.

Supabase unavailable:

- Save local mapping.
- Mark `sync_status = failed`.
- Retry later.

User not logged in:

- Save local mapping only.
- Sync when authenticated.

Known bank profile missing:

- Mapping can still be confirmed as sender identity.
- Transactions remain generic pending.

Profile exists but parser confidence low:

- Keep pending or ignored based on normal parser rules.
- Do not ask Gemini parser unless generic parse fails below threshold and user AI consent allows it.

## 18. Edge Cases

- Same sender used by multiple banks in different countries.
- Sender string changes casing or contains prefixes.
- Sender is a phone number but SMS text clearly says bank.
- User rejects then later wants to confirm.
- User confirms wrong bank.
- Remote mapping from another device conflicts with local rejection.
- Bank renamed.
- Bank merger.
- Multi-language SMS from same sender.
- Shared payment processors sending for multiple institutions.
- SIM/device locale differs from bank country.
- User turns off AI after a pending suggestion exists.

Handling:

- Normalize sender conservatively.
- Keep user-edit/delete path in Settings.
- Do not make confirmed mapping immutable.
- Consider country/currency hint but do not rely on it alone.
- Treat shared senders as not eligible unless confidence is extremely high and user confirms.

## 19. Implement Now Vs Later

Implement now:

- Drift table.
- Repository.
- Local mapping lookup.
- Confirm/reject use cases.
- Gemini discovery client interface.
- Fake client tests.
- Confirmation bottom sheet.
- AI skip guarantee for confirmed mappings.
- Supabase migration/RLS if backend work is in scope.

Implement later:

- Manual bank selector in Settings.
- Global anonymized discovery analytics.
- Admin review of suggested unknown banks.
- Public/community bank mappings.
- Auto-suggest parser profile creation.
- UAE shared base parser extraction.
- Bank discovery model evaluation dashboard.

Do not implement:

- Auto-create banks from Gemini.
- Auto-confirm transactions because Gemini identified a bank.
- Store raw SMS in Supabase.
- Share user sender mappings globally.

## 20. Estimated Task Breakdown

### Task A — Local Data Layer

Estimate: 0.5-1 day

- Add entity.
- Add Drift table/migration.
- Add repository.
- Add repository tests.

### Task B — Bank Discovery Domain Layer

Estimate: 0.5-1 day

- Add suggestion entity.
- Add use cases: resolve, confirm, reject.
- Add eligibility rules.
- Add unit tests.

### Task C — Gemini Client

Estimate: 0.5-1 day

- Add client interface.
- Add Gemini implementation.
- Add sanitizer.
- Add JSON schema parser.
- Add timeout/error tests.

### Task D — Parser Pipeline Integration

Estimate: 1 day

- Add lookup before bank detection fallback.
- Ensure confirmed mapping skips Gemini.
- Ensure generic pending does not call AI discovery repeatedly.
- Add regression tests.

### Task E — Confirmation UX

Estimate: 1 day

- Add bottom sheet.
- Add controller/provider.
- Wire into capture/app shell flow.
- Add widget tests.

### Task F — Supabase Sync

Estimate: 1 day

- Add migration.
- Add RLS policies.
- Add sync service.
- Add retry behavior.
- Add integration-style tests where possible.

### Task G — Settings Management

Estimate: 0.5-1 day

- Add settings screen.
- Add delete/reject/re-enable actions.
- Add tests.

### Total MVP Estimate

4.5-7 days, depending on current app shell complexity and Supabase test harness availability.

## Recommended First Implementation Task

Start with Task A: local Drift table + repository + tests.

Reason:

- It creates the durable contract for the whole feature.
- It can be built without Gemini, UI, or Supabase risk.
- It immediately enables the most important future behavior: confirmed sender mappings can bypass Gemini forever.
