# 22 — Coding Standards

Related: [01_GLOBAL_RULES.md](01_GLOBAL_RULES.md), [06_FLUTTER.md](06_FLUTTER.md), [05_BACKEND.md](05_BACKEND.md).

## 1. Dart/Flutter style

- Follow `flutter_lints` defaults (`analysis_options.yaml`); `flutter analyze` must report 0 issues before any commit.
- File naming: `snake_case.dart`, mirroring the class it primarily defines (e.g. `drift_account_repository.dart` defines `DriftAccountRepository`).
- One primary public class per file, with small private helper classes co-located when they're only meaningful in that file's context.
- Prefer `final`/`const` aggressively; avoid mutable module-level state except for the small number of deliberate singletons already in the codebase (`CaptureRuntime.instance`, `LocalNotificationService.instance`) — see [06_FLUTTER.md](06_FLUTTER.md) §3 for the caching pitfall these singletons must be wired around.
- Comments explain **why**, never **what** — see [01_GLOBAL_RULES.md](01_GLOBAL_RULES.md) default-no-comments guidance in the broader engineering conventions this project follows. A comment justifying a non-obvious constraint (e.g., "epoch-0 timestamp is a namespace signal, not a real time — see REG-005") is valuable; a comment restating a well-named function's behavior is not.
- Arabic-language comments are used throughout this codebase for domain-specific business-rule explanations (transfer accounting, dedup semantics) — this is intentional given the team's working language, not inconsistent style. New comments of this kind should follow the same convention rather than switching to English mid-file.

## 2. Domain/data layer conventions

- `domain/` never imports `package:flutter/*`, `package:drift/*`, or `package:supabase_flutter/*` — it is pure Dart, defining interfaces and use cases only.
- Every repository interface in `domain/repositories/` has exactly two production implementations (`Drift*Repository`, `Supabase*Repository`) and one router (`Routed*Repository`) — see [03_ARCHITECTURE.md](03_ARCHITECTURE.md) §4. A new financial entity being migrated to Supabase-primary must follow this exact three-file pattern, not a bespoke variant.
- Entities (`domain/entities/`) are immutable value objects with `copyWith` — never mutable model classes with setters.
- Use cases (`domain/usecases/`) orchestrate repositories and services; they contain business logic, not repositories themselves (a use case depends on repository *interfaces*, injected).

## 3. Error handling conventions

- Every Supabase repository method funnels raw errors through `mapSupabaseError()` — never let a raw `PostgrestException`/`AuthException` reach the UI layer directly.
- UI code catches the specific `RepoException` subtype it can meaningfully react to (e.g., `DuplicateRepoException` to show "already exists"), falling back to the generic `repoExceptionMessage()` for anything else — never a bare `catch (e) { print(e); }` in production code paths.
- Never swallow an error silently in a way that hides a real failure from the user, **except** where explicitly documented as intentional (e.g., mirror-write failures after a successful authoritative Supabase write — see [03_ARCHITECTURE.md](03_ARCHITECTURE.md) §4).

## 4. Deno/Edge Function conventions

- File naming: `kebab-case` directories per function (`process-ios-sms/index.ts`), shared modules under `_shared/`.
- Every function validates its inputs explicitly (`readString`, type-checking `body` fields) before use — never trust the request body's shape.
- Structured JSON logging only (`console.log(JSON.stringify({ event: '...', ...safeFields }))`) — never string-interpolated logs that might accidentally include a raw text field (see [07_SECURITY.md](07_SECURITY.md) §4.3).
- Shared logic used by more than one function (auth, fingerprinting, APNs) lives in `_shared/`, imported by relative path — do not duplicate logic across functions when a shared module already exists or clearly should.
- Any function performing a write that could plausibly be retried (client timeout, network blip) must be idempotent per some caller-supplied key — see [14_SMS_CAPTURE_PIPELINE.md](14_SMS_CAPTURE_PIPELINE.md) §3 for the `payloadId` contract this project relies on.

## 5. SQL/migration conventions

- Every migration file is named `NNNN_description.sql`, four-digit zero-padded, strictly sequential — confirm the next number against both the highest existing file **and** `supabase migration list` before creating a new one (they must agree).
- Every migration has a matching `supabase/rollback/NNNN_description_rollback.sql`.
- Prefer `CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`-equivalent idempotent DDL where the migration might plausibly be re-run (some migrations in this project's history are explicitly non-idempotent DDL by necessity — document clearly when that's the case).
- Every RLS-relevant table states its policy explicitly in the same migration that creates it — never leave a table with RLS enabled but no policy (which defaults to fully denying everyone including the owner in some contexts) or RLS disabled by omission.
- Comments in migration files explain the *business* reason for a schema decision (e.g., why a column is nullable, why an index is structured a certain way) — see `0027_fix_upsert_conflict_indexes.sql`'s extensive comment explaining the partial-index/upsert bug as the house style to match.

## 6. Testing conventions

See [06_FLUTTER.md](06_FLUTTER.md) §7 for the Dart testing patterns (in-memory Drift, mocked HTTP, fake platform interfaces) and [10_TEST_STRATEGY.md](10_TEST_STRATEGY.md) for the overall strategy. Style specifics:

- Test file mirrors the production file's path under `test/`.
- Test names are full sentences describing the exact scenario ("failed ack followed by dedup prune must not re-import the capture"), not generic ("test sync").
- Arrange/Act/Assert structure, even without explicit section comments — a reader should be able to tell the three phases apart at a glance.
- No live network calls in unit/integration tests, ever — use `MockClient`/fakes as described in [06_FLUTTER.md](06_FLUTTER.md) §7.

## 7. Documentation conventions (this handbook and in-code)

- In-code documentation comments (`///` in Dart, `//` block headers in TS/SQL) are reserved for non-obvious constraints, not restatements of the function name.
- This handbook is updated in the same change as anything that alters architecture, schema, or process — see README.md "Maintenance." A change that contradicts this handbook without updating it is treated as a documentation bug, filed the same way a code bug would be ([17_BUG_WORKFLOW.md](17_BUG_WORKFLOW.md)).
