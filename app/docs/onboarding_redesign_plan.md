# Onboarding Redesign — Implementation Plan (for Opus)

> **How to use this document**: implement it literally, phase by phase, in order.
> Every file path, symbol, and API named here was verified against the codebase on
> 2026-07-05 (branch `feat/accounts-multicurrency`). If reality contradicts this
> plan, STOP and surface the contradiction — do not silently improvise.
> Run from `app/` (Flutter project root). Do NOT commit — leave changes in the
> working tree. Gates before declaring done:
> `flutter analyze` (0 issues) → `flutter test` (all pass, currently 472) →
> `flutter gen-l10n` only if you touch ARB files.

---

## 0. Product decisions (already made — do not reopen)

> **CORRECTION (2026-07-05, after tracing reality):** the original §1 facts
> missed that `LuxeOnboardingScreen` is a 6-page (iOS) PageView container serving
> auth + country/currency + setup — NOT a story screen — and that the real
> first-run story gate is `QirshWelcomeManifestoScreen` at `/welcome`. Country/
> currency selection and guest mode also existed and were unaccounted for. The
> decisions below supersede the original 4-page routing. User decided (verbatim):
> - **Country/currency** → becomes the FIRST step of the setup page (§2.2 step 0).
> - **Guest mode** → removed entirely (session + redirect).

1. **Four pages**, replacing the current onboarding maze:
   - Page 1 `/welcome` — cinematic story (replaces `QirshWelcomeManifestoScreen`;
     keeps the existing first-run redirect gate that forces `/welcome` while
     `!hasSeenWelcomeManifesto`). Flutter animations, NOT video files.
   - Page 2 `/onboarding/brand` — cinematic continuation + logo reveal. Story's
     last act calls `markWelcomeManifestoSeen()` then `go('/onboarding/brand')`.
   - Page 3 `/onboarding/auth` — **mandatory** auth (Google / Apple). No guest.
   - Page 4 `/onboarding/setup` — activation checklist: **country/currency** →
     notifications → cloud-processing consent → Shortcut install → verify,
     ending in "ابدأ" → home.
2. **Restore prompt** becomes a conditional dialog after auth — shown only when a
   backup actually exists for the signed-in account.
3. Everything else in `lib/features/onboarding/` is deleted or folded in
   (disposition table in §5).
4. Visual language: true-black background (`#000000`), existing `AppColors`
   (`lib/core/theme/app_colors.dart` — do NOT invent a new palette),
   `flutter_animate` for motion, gold accent `Color(0xFFDAA520)` (`_kGold` in the
   current luxe screen) reserved for the logo-reveal moment only.
   Reuse `lib/features/onboarding/widgets/luxe_starry_bg.dart` as the shared
   animated background across pages 1–3 if it fits; otherwise build one shared
   `OnboardingBackdrop` widget — never per-page copies.
5. Arabic-first copy, hardcoded Arabic strings like the rest of the feature
   screens (the app's newer screens hardcode Arabic; follow that, no ARB work).

---

## 1. Verified codebase facts you will build on

| Fact | Where |
|---|---|
| Session flags: `hasCompletedOnboarding`, `hasSeenWelcomeManifesto` | `lib/core/session/app_session.dart:34-35` |
| `AppSession.completeOnboarding({required String method, String? email})` — sets identity + finishes onboarding | `app_session.dart:93` |
| `AppSession.markWelcomeManifestoSeen()` | `app_session.dart:53` |
| Auth API: `Future<AuthIdentity> signInWithGoogle()` / `signInWithApple()` | `lib/core/auth/auth_service.dart:20-21` |
| Notification permission: `LocalNotificationService.requestPermissionsIfNeeded()` | `lib/features/capture/services/local_notification_service.dart:144` |
| Settings entity fields: `cloudProcessingEnabled` (default false), `aiConsentGranted` (default false) | `lib/domain/entities/supporting_entities.dart:151-177` |
| Settings persistence: `DriftUserSettingsRepository.getSettings()` / `saveSettings(settings.copyWith(...))` | used across settings/capture services |
| **Critical**: after enabling cloud processing you MUST call `ref.read(captureDeviceRegistrationServiceProvider).syncNativeState()` — it writes the App Group backend config, registers the device, and uploads the APNs token. Without it the iOS Shortcut cannot reach the backend (this exact omission caused a week of bugs). | `lib/features/capture/services/capture_device_registration_service.dart:27` |
| Shortcut-verify pattern: `Timer.periodic(2s)` polling + re-poll on `AppLifecycleState.resumed` | `lib/features/onboarding/ios_shortcut_verify_screen.dart:38-60` — read `_poll()` before rewriting; reuse its detection logic verbatim |
| Router: onboarding routes + redirect live in `lib/core/router/app_router.dart` (`onboardingEntryPathForSession` at line 34, redirect at 49-70, routes from line 83) |
| Backup existence check: `BackupService` abstract class | `lib/core/backup/backup_service.dart:31` — find the "does a backup exist" method there; `restore_prompt_screen.dart` shows current usage |
| Shared motion widgets | `lib/features/common/motion.dart` |

---

## 2. Phase A — Pages 3 & 4 (functional core; do this first)

### 2.1 New file: `lib/features/onboarding/auth_screen.dart`

`OnboardingAuthScreen` (ConsumerStatefulWidget), route `/onboarding/auth`
(route NAME stays `onboarding-auth` — the router redirect references the path).

Layout (top → bottom):
- Shared animated backdrop (same widget as pages 1–2, calmer parameters).
- Qirsh logo, small, centered top third (`AppAssets` has the brand assets —
  `lib/core/theme/app_assets.dart`).
- Headline: `سجّل دخولك` / sub: `حسابك بيحمي بياناتك ويخلي كل حاجة متزامنة.`
- Two full-width buttons: "المتابعة بحساب Apple" (SignInWithApple style guidelines,
  black bg white text) then "المتابعة بحساب Google".
- NO guest/skip option anywhere.

Behavior:
- Tap → call `signInWithApple()` / `signInWithGoogle()` from the auth service
  provider (find the provider in `lib/core/di/app_providers.dart` — the current
  luxe screen imports and uses it; copy that call pattern including error
  handling and any `sign_in_with_apple` platform checks).
- On success:
  1. `await session.completeOnboarding(method: 'apple'|'google', email: identity.email)`
     — **but check first**: the current luxe screen may call `setIdentity` +
     defer `finishOnboarding` until setup completes. Preserve the invariant:
     *auth success must NOT mark onboarding complete* — completion happens only
     at the end of page 4. If `completeOnboarding` conflates both (it calls
     `finishOnboarding()`), use `setIdentity(...)` here and call the finishing
     API only from page 4. Read `app_session.dart:93-97` and mirror how
     `completion_screen.dart` finishes today.
  2. Backup check: query `BackupService` for an existing backup for this account.
     If one exists → show a modal dialog: `لقينا نسخة احتياطية لحسابك` with
     buttons `استرجاعها` (runs the restore exactly as `restore_prompt_screen.dart`
     does today — move that logic, don't rewrite it) and `ابدأ من جديد`.
  3. `context.go('/onboarding/setup')`.
- Loading state on the pressed button; auth errors → SnackBar in Arabic
  (`تعذّر تسجيل الدخول. جرب تاني.`), never a dead end.

### 2.2 New file: `lib/features/onboarding/setup_screen.dart`

`OnboardingSetupScreen` (ConsumerStatefulWidget), route `/onboarding/setup`.
One screen, four sequential steps rendered as a vertical checklist. Each step is
a card with: icon, title, one-line description, action button, and a ✓ state.
Steps unlock top-to-bottom (step N+1 disabled until N done). A thin progress
bar at top fills 25% per completed step.

**Step 1 — الإشعارات** (`فعّل الإشعارات — عشان توصلك كل عملية فور حدوثها`)
- Button `تفعيل` → `await LocalNotificationService.requestPermissionsIfNeeded()`
  (get the instance the way `app_shell.dart` / existing onboarding does — via
  provider, not a new construction).
- Mark done when the call returns (do not block on the user actually granting;
  iOS returns after the dialog).

**Step 2 — المعالجة الذكية** (`فعّل قراءة رسائل البنك — بنحللها ونسجل عملياتك تلقائياً`)
- Body includes one consent line: `بتفعيلك بتوافق على معالجة نصوص رسائل البنك
  سحابياً لتحليلها. بياناتك متشفرة ولا نخزن أرقامك الكاملة.`
- Button `موافق وفعّل` →
  ```dart
  final repo = ref.read(userSettingsRepositoryProvider); // find exact provider name in app_providers.dart
  final s = await repo.getSettings();
  await repo.saveSettings(s.copyWith(
    cloudProcessingEnabled: true,
    aiConsentGranted: true,
  ));
  await ref.read(captureDeviceRegistrationServiceProvider).syncNativeState();
  ```
- The `syncNativeState()` call is NON-NEGOTIABLE (see §1). Wrap in try/catch;
  on failure still mark the step done but schedule a retry on page exit
  (the app also re-syncs on every launch, so this is safe).

**Step 3 — اختصار الرسائل** (`ثبّت اختصار قِرش — هو اللي بيبعتلنا رسائل البنك`)
- Move the install content from `ios_shortcut_screen.dart`: the shortcut gallery
  URL constant, the step-by-step instructions (keep its `_Step` data), and the
  "افتح الاختصار" button that launches the URL via `url_launcher`.
- Compress the visual: horizontal mini-carousel of the instruction steps instead
  of a full screen.
- Mark done when the user taps `ثبّتّه` (self-declared — we can't detect install).

**Step 4 — جرب بنفسك** (`ابعت رسالة تجربة وشوف قِرش بيشتغل`)
- Move the polling logic from `ios_shortcut_verify_screen.dart` verbatim:
  `Timer.periodic(2s)` + lifecycle-resume re-poll, and whatever `_poll()` checks
  (read it first — it detects the first captured transaction).
- Show a "بنستنى أول رسالة..." pulsing state; when the poll detects a capture →
  swap to ✓ + `وصلت! قِرش سجّلها.` with a subtle celebration
  (`flutter_animate` scale+fade, nothing heavy).
- Include a `تخطي دلوقتي` text button (small, low emphasis) — verification must
  be skippable or users without a bank SMS at hand get stuck.

**Finish** — full-width `ابدأ` button, enabled when steps 1–3 done (step 4
optional): call the same finishing API `completion_screen.dart` uses today
(find it — it is "the single place that finishes onboarding", its doc comment
says so), then `context.go('/')`.

### 2.3 Router changes — `lib/core/router/app_router.dart`

- `onboardingEntryPathForSession` (line 34): new logic —
  ```dart
  if (session.hasCompletedOnboarding) return '/onboarding/auth'; // signed-out returning user
  if (session.hasSeenWelcomeManifesto) return '/onboarding/auth'; // saw story before
  return '/onboarding';
  ```
  (Semantics preserved: story pages show once per install; auth/setup always
  reachable. Verify against the existing redirect at lines 49-70 and keep its
  auth-completion checks working.)
- Routes: keep `/onboarding`, `/onboarding/auth`, `/onboarding/setup` (point them
  at the new screens); ADD `/onboarding/brand`; DELETE routes + imports for:
  `method-picker`, `manual`, `method`, `restore`, `ios-shortcut`, `listening`,
  `otp`, `privacy`, and the verify/first-transaction/completion routes (grep the
  router for every `/onboarding/` path and reconcile against §5).

### 2.4 Deletions (Phase A scope) & reference sweep

Delete: `capture_method_picker_screen.dart`, `method_screen.dart`,
`listening_screen.dart`, `otp_screen.dart`, `first_transaction_screen.dart`,
`completion_screen.dart` (after moving its finishing call into setup),
`ios_shortcut_screen.dart` + `ios_shortcut_verify_screen.dart` (after moving
their content), `restore_prompt_screen.dart` (after moving restore into auth).

After each deletion: `grep -rn "<DeletedClassName>" lib/ test/` — fix every
dangling import/reference. Some tests may reference these screens; update or
delete those tests to match the new flow.

**Keep** `force_update_screen.dart` (not part of onboarding flow) and
`onboarding_options.dart` ONLY if still referenced after the sweep.

---

## 3. Phase B — Pages 1 & 2 (cinematic)

### 3.1 New file: `lib/features/onboarding/story_screen.dart` (route `/onboarding`)

Auto-advancing 3-act sequence (each act ~4s, progress dots at top like stories
UI; tap-right = next act, tap-left = previous, swipe up on last act → page 2).

- **Act 1 — الفوضى**: dark void; Arabic SMS fragments (fake bank-message
  snippets) float up like debris, blurred and overlapping, slight rotation
  drift. Copy fades in: `رسايل البنك كتير…` then `وفلوسك ضايعة بينهم.`
- **Act 2 — الالتقاط**: one message snippet pulls into center, unblurs, and
  visually "transforms": numbers slide out of it into a clean row
  (amount ريال/جنيه, merchant, category chip). Copy: `قِرش بيقراها في ثانية…`
- **Act 3 — الوضوح**: the clean row multiplies into a mini animated bar chart
  rising bottom-up. Copy: `وبيحوّلها لصورة كاملة لفلوسك.`
- Implementation: one `AnimationController` per act driving staggered
  `flutter_animate` chains; message-fragment widgets are plain `Text` in
  `Positioned` — no images needed. 60fps target: no blur animations wider than
  a few widgets (`ImageFiltered` is expensive — static blur + animated opacity
  instead).
- Bottom: `تخطي` (small) → `/onboarding/auth` + `markWelcomeManifestoSeen()`.

### 3.2 New file: `lib/features/onboarding/brand_screen.dart` (route `/onboarding/brand`)

Single continuous sequence (~5s) then rests:
- Particles/stars from the backdrop converge toward center (reuse/parametrize
  `luxe_starry_bg.dart`), condense into the Qirsh logo
  (`AppAssets` brand asset — pick the dark-bg variant), logo scales in with the
  gold `#DAA520` glow pulse ONCE, then tagline fades under it:
  `قِرش — فلوسك واضحة.`
- CTA fades in after the reveal: full-width `يلا نبدأ` → calls
  `session.markWelcomeManifestoSeen()` then `context.go('/onboarding/auth')`.
- Story page's last act auto-navigates here with `context.go` — the transition
  between the two pages must feel continuous (same backdrop widget instance
  style, no hard cut: use a `PageRouteBuilder`/go_router `pageBuilder` with
  fade-through, 400ms).

---

## 4. Sequencing, gates, and acceptance

Implement in this order, running gates after each numbered step:

1. Phase A: `setup_screen.dart` (biggest risk) → 2. `auth_screen.dart` + restore
   dialog → 3. router rewire + deletions + reference sweep → **gates** →
4. Phase B: `story_screen.dart` → 5. `brand_screen.dart` → **gates**.

Acceptance checklist (verify each by reading the code paths, and on simulator
`flutter run -d "Mali-iPhone"` if available):

- [ ] Fresh install: `/onboarding` → `/onboarding/brand` → `/onboarding/auth` →
      `/onboarding/setup` → home. No other onboarding route reachable.
- [ ] Kill the app mid-flow at every page: relaunch resumes at the correct page
      (story pages never repeat once `markWelcomeManifestoSeen` fired; setup
      resumes if authed but not finished).
- [ ] No guest path exists; back-swipe from auth does not escape onboarding.
- [ ] Setup step 2 leaves `cloudProcessingEnabled=true`, `aiConsentGranted=true`
      in settings AND `syncNativeState()` was invoked (add a focused test for the
      settings write if a natural seam exists).
- [ ] Signed-in user with an existing backup sees the restore dialog exactly once.
- [ ] `flutter analyze` 0 issues; `flutter test` all pass; deleted screens leave
      zero dangling references (`grep` proof).
- [ ] Story/brand pages hold 60fps on simulator (no jank warnings in console).

## 5. Old-screen disposition (single source of truth)

| File | Fate |
|---|---|
| `qirsh_welcome_manifesto_screen.dart`, `luxe_onboarding_screen.dart` | DELETE — replaced by story/brand/auth (move any still-needed auth call patterns into `auth_screen.dart` first) |
| `otp_screen.dart` | DELETE (no email OTP in the new flow) |
| `capture_method_picker_screen.dart`, `method_screen.dart` | DELETE |
| `listening_screen.dart` | DELETE (Android SMS path — not in iOS flow) |
| `ios_shortcut_screen.dart`, `ios_shortcut_verify_screen.dart` | FOLD into setup steps 3–4, then DELETE |
| `restore_prompt_screen.dart` | FOLD into auth-success conditional dialog, then DELETE |
| `first_transaction_screen.dart` | DELETE |
| `completion_screen.dart` | FOLD its finishing call into setup's ابدأ, then DELETE |
| `force_update_screen.dart` | KEEP (unrelated) |
| `widgets/luxe_starry_bg.dart` | KEEP + reuse as shared backdrop |

## 6. Hard constraints

- Do not touch: capture pipeline (`lib/features/capture/`), Swift/iOS native
  code, edge functions, sync engines, feature flags, DB schema.
- No new dependencies. No ARB/l10n changes. Match existing code style.
- Do not commit; leave the working tree for review.
- If any verified fact in §1 turns out wrong, stop and report it instead of
  working around it.
