# Mali Onboarding Current Inventory

Scope: onboarding-related screens and setup flows only. This inventory was prepared for a design handoff and does not propose Flutter implementation changes.

## A. Onboarding File Map

| File path | Purpose | Screen/widget | Route | Main UI sections | Data/state used | Actions/buttons | Current text/content | Assets/icons used | AR/EN aware | RTL/LTR safe | Problems found |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `app/lib/app.dart` | App root, localization/theme, splash overlay | `MoneyApp`, `_RizonSplashGate`, `_MaliSplash` | Global wrapper before router child | Animated Mali logo, Arabic title, latin `M A L I`, loading bar | `themeModeProvider`, `localeProvider`; 1400ms local splash timer | None | `مالي`, `M A L I` | Programmatic geometric logo; no image asset | Partly: app locale global, splash text hardcoded | Mostly safe; Arabic/Latin direction is manually set | Splash is visually separate from onboarding; no explicit value/trust message; hardcoded splash name `_RizonSplashGate` |
| `app/lib/core/router/app_router.dart` | GoRouter route table and onboarding redirect | `appRouter` | `/onboarding`, `/onboarding/auth`, `/onboarding/method`, `/onboarding/restore`, `/onboarding/ios-shortcut`, `/onboarding/listening`, `/onboarding/ios-verify`, `/onboarding/first-transaction`, `/onboarding/otp` | Redirects unauthenticated first-run users into onboarding | `AppSession.instance.status`, `AppSession.instance.isGuest` | Automatic redirect; allows guest auth upgrade to auth/otp | No UI copy | None | N/A | N/A | Current logic treats any `/onboarding/*` as onboarding; post-auth routing depends on `AppSession` refresh timing |
| `app/lib/core/session/app_session.dart` | First-run/session flags | `AppSession` | Used by router | No UI | Secure storage keys: `onboarding_done`, `auth_method`, `auth_email`; status `unknown/needsOnboarding/authenticated`; guest support | `setIdentity`, `finishOnboarding`, `continueAsGuest`, `signOut`, `wipeAndReset` | No UI copy | None | N/A | N/A | Guest mode exists in code, but product preference says email should be required; preserve logic unless Flutter implementation is explicitly approved |
| `app/lib/main.dart` | Bootstraps session/catalog/capture before app | `_bootstrap()` | App startup | No UI | Supabase, `AppSession.load`, database, catalog seed, notification route, capture runtime | None | No UI copy | None | N/A | N/A | No standalone launch screen route; splash is an overlay in `app.dart` |
| `app/lib/features/onboarding/onboarding_screen.dart` | Main 4-page onboarding intro | `OnboardingScreen`, `_WelcomePage`, `_HowItWorksPage`, `_PrivacyPage`, `_CountryPage` | `/onboarding` | Top progress pill + skip; page view: welcome, how it works, privacy, country/currency; bottom dots + CTA | `onboardingSelectionProvider`; `saveCountryCurrencyUseCaseProvider` on final CTA | Next, skip to auth, country picker, final `registerAndStart` | Localized: welcome, SMS-to-transaction, privacy rules, country/currency. Hardcoded preview text: `BURGER BOUTIQUE`, `رسالة بنك -> عملية مصنفة -> رؤية واضحة` | `MaliLogo`, `AppLucideIcons`, Material icons, flag SVGs | Mostly AR/EN via `context.l10n`; some hardcoded Arabic preview copy | Mostly direction-aware; uses physical `SizedBox(width)` and left/right in places | Four pages are clearer than one screen, but visual hierarchy is generic; fake dashboard preview can drift; skip appears before auth; hardcoded colors and `_alex` typography clone |
| `app/lib/features/onboarding/onboarding_options.dart` | Country/currency data and selection provider | `onboardingSelectionProvider`, `OnboardingCountry`, `currencyKeywords` | Used by `/onboarding` and iOS verification | No screen; country/currency list data | Default country Saudi Arabia; keyword mapping for SAR/AED/EGP/KWD/QAR/BHD/OMR/JOD | Country selection writes provider state | Country/currency names in Arabic plus English lookup maps | Flag assets referenced from `assets/flags/{code}.svg` | Yes for country/currency labels | N/A | Country catalog is hardcoded here while full catalog JSON also exists; no standalone language selection |
| `app/lib/features/onboarding/auth_screen.dart` | Sign-in gate | `AuthScreen` | `/onboarding/auth` | Back button, logo, headline/subtitle, trust chips, Apple, Google, email OTP field/button, guest/no-account links, terms text | `authServiceProvider`, `_busy`, `AppSession.setIdentity` | Apple sign-in, Google sign-in, send OTP, guest continue, continue without account | Localized auth strings; hardcoded Arabic snack error and trust chips `خصوصية`, `نسخ اختياري`, `بدون كلمة مرور`; hardcoded `المتابعة بدون حساب` | `MaliLogo`, `SignInWithAppleButton`, custom-painted Google mark, Material icons | Mixed: key strings localized, several Arabic-only strings | Email field LTR; back arrow appears as `arrow_forward` | Too many paths; duplicate guest/no-account controls; current user preference says email should be necessary; no loading overlay except disabled/busy |
| `app/lib/features/onboarding/otp_screen.dart` | Email code verification | `OtpScreen` | `/onboarding/otp` | Back button, mail icon, title/subtitle, email, 6-digit field, verify CTA, demo-code chip | `authServiceProvider.verifyEmailCode`, `_busy`, `_error`, `AppSession.setIdentity` | Verify code; back | Localized OTP strings; demo code `123456` shown | Material mail icon, `GlowingIcon` | Yes | Numeric field centered; email LTR | Demo code should not be prominent in production design; no resend state in current UI; error only in field |
| `app/lib/features/onboarding/method_screen.dart` | Post-auth capture setup sheet | `OnboardingMethodScreen`, `IosShortcutGuide`, `_AiConsentCard`, `showIosShortcutSheet` | `/onboarding/method`; also settings sheet reuse | Bottom sheet with drag handle, gradient hero, Android instructions or iOS 8-step guide, multi-currency note, AI consent, Got it, later/manual | Platform check, `baseCurrencyProvider`, `backupServiceProvider.hasRemoteBackup`, `userSettingsProvider.aiConsentGranted`, `AndroidSmsCaptureService.requestPermissions`, `AppSession.finishOnboarding` | Got it/request SMS or verify iOS, later add manually, AI consent toggle | Mixed localized and hardcoded Arabic. Android/iOS steps have AR/EN branches; AI consent hardcoded Arabic; multi-currency note hardcoded Arabic | Material SMS/iOS/share/info/AI icons | Partial | Sheet is generally RTL but uses many physical paddings | Very dense; country/DOB are expected in some docs but current code only has capture setup and AI consent; iOS guide is long; privacy/trust explanation is small; no visible success state here |
| `app/lib/features/onboarding/ios_shortcut_screen.dart` | Standalone iOS Shortcut instructions | `IosShortcutScreen` | `/onboarding/ios-shortcut` | Back button, Apple icon, title/subtitle, 8 numbered steps, multi-currency card | `baseCurrencyProvider` | Back only | AR/EN step lists, localized title/subtitle | Material Apple/shortcut/step icons | Yes | Direction-aware back icon | Similar content duplicated with `IosShortcutGuide` inside method sheet; no primary action or verify CTA in this standalone screen |
| `app/lib/features/onboarding/ios_shortcut_verify_screen.dart` | iOS Shortcut verification waiting loop | `IosShortcutVerifyScreen` | `/onboarding/ios-verify` | Center icon, title/body, keyword chip, loading row, re-check, paste fallback, skip | Poll timer; lifecycle resume; `NativeCaptureBridge.consumePendingSharedMessages`; `CapturedMessageProcessor`; backup check; `AppSession.finishOnboarding` | Re-check setup, paste message, skip | Localized title/body/waiting/buttons; keyword from selected currency | Material iOS share icon and progress spinner | Yes | Mostly safe; keyword is Latin | Success depends on receiving a message; waiting state lacks enough visual instruction; skip can end onboarding without capture proof |
| `app/lib/features/onboarding/listening_screen.dart` | Android/shared-message waiting state | `ListeningScreen` | `/onboarding/listening` | Pulse icon, title/subtitle, paste fallback, skip | `AndroidSmsCaptureService.startListeningIfPermitted`, `CaptureRuntime.confirmRequests`, backup check, `AppSession.finishOnboarding` | Paste bank message, skip | Localized waiting strings | Material wifi-tethering icon | Yes | Centered content is safe | Permission-denied/permission-granted distinctions are not visible; skip ends onboarding without first transaction |
| `app/lib/features/onboarding/first_transaction_screen.dart` | First captured transaction success/review | `FirstTransactionScreen` | `/onboarding/first-transaction` | Loading/error/pending/confirmed states; transaction card; category change; continue | `transactionByIdProvider`, `categoryCatalogProvider`, transaction status, `showConfirmTransactionSheet`, `showChangeCategorySheet`, `AppSession.finishOnboarding` | Confirm pending transaction, change category, continue | Localized state text; source labels partly hardcoded AR/EN | Category icons/colors, SMS icon | Partial | Amount/currency LTR-friendly via tabular text | Error fallback is weak; pending and confirmed states are functional but not celebratory enough; calls transaction sheets from onboarding |
| `app/lib/features/onboarding/restore_prompt_screen.dart` | Restore existing encrypted backup | `RestorePromptScreen` | `/onboarding/restore`, `/backup/restore` | Bottom card, trust hero, passphrase/recovery-code field, restore CTA, start fresh/not now | `backupServiceProvider.restoreFromBackup`, `_busy`, `_error`, `_useRecoveryCode`, provider invalidation, `AppSession.finishOnboarding` | Restore, switch password/recovery mode, start fresh | Localized backup/restore strings | Material lock-reset icon | Yes | Mostly safe | Good security model, but layout is form-heavy; success state just routes away; no recovery education beyond text |
| `app/lib/features/capture/sms_permission_screen.dart` | Manual share/paste explanation sheet | `SmsPermissionScreen` | `/capture/sms-permission`; also `showSheet` | RTL bottom sheet, receipt icon, title/subtitle, example card, paste CTA, later text | Local UI state only | Paste manual message, close/later | Hardcoded Arabic only | `AppLucideIcons.receipt`, close icon | No | Forces RTL explicitly | Despite ARB SMS permission strings existing, this screen bypasses them; it explains sharing/manual paste, not actual Android runtime permission state |
| `app/lib/features/capture/manual_paste_screen.dart` | Manual fallback used during onboarding verify/listening | `ManualPasteScreen.showSheet` | `/paste`; sheet from onboarding | Manual SMS paste flow | Capture/ingest pipeline | Paste/import transaction | Not fully inventoried here; included because onboarding uses it as fallback | Material/common app icons | Mixed | Likely RTL sheet | Claude should design it only as an onboarding fallback reference, not a full transaction feature |
| `app/lib/features/backup/backup_screen.dart` | Backup setup after onboarding/settings | `BackupScreen` | `/backup` | Header, loading/error, guest gate, enabled backup, enable flow, recovery code | `backupStatusProvider`, `backupServiceProvider`, `AppSession.isGuest` | Sign in, enable, backup now, restore, disable, copy recovery code | Hardcoded Arabic | Material cloud/lock/warning/restore icons | No | Mostly RTL by app locale, but copy Arabic-only | Trust model is strong but not premium; no onboarding-specific backup explainer screen unless remote backup exists |
| `app/lib/features/settings/privacy_screen.dart` | Privacy/data management related to trust story | `PrivacyScreen` | `/privacy` | Header, privacy policy, terms, export, backup, danger delete | `dataWipeServiceProvider`, `AppSession.wipeAndReset` | Open links, export, backup, delete/reset | Hardcoded Arabic; external policy/terms URLs | Material document/gavel/download/cloud/delete icons | No | Mostly safe | Trust story is buried in settings; not directly part of first-run except privacy page |
| `app/lib/features/onboarding/force_update_screen.dart` | Blocking force-update gate | `ForceUpdateScreen` | Rendered by `AppShell` when force update flag active | Centered update icon/text/button | `activeAnnouncementsProvider`, `hasForceUpdateProvider` in shell | Update now | Announcement Arabic fields or fallback Arabic | Material system-update icon | No | N/A | Not onboarding, but can block newly onboarded users; app-store URL placeholder |
| `app/lib/features/onboarding/widgets/premium_ui.dart` | Onboarding UI primitives | `PremiumBackground`, `GlassCard`, `GlowingIcon` | Used across onboarding | Safe area scaffold, flat card, icon wrapper | Theme colors only | Optional card tap | No user copy | Material icons via child | N/A | Depends on parent | Named "GlassCard" but now flat card; not enough shared structure for complex onboarding |
| `app/lib/features/onboarding/widgets/bento_card.dart` | Bento-style onboarding visual primitive | `BentoCard`, `BentoRow` | Reusable component | Themed cards/rows | Theme colors only | Optional tap | No user copy | None | N/A | N/A | Hardcoded gradient colors remain in enum themes; not used heavily in current flow |
| `app/lib/core/i18n/locale_provider.dart` | Language selection source | `localeProvider` | Global app | No UI | `userSettingsProvider.language`; defaults Arabic | None | No UI copy | None | Supports AR/EN | Direction comes from locale | There is no standalone first-run language selection screen |
| `app/lib/l10n/app_ar.arb`, `app/lib/l10n/app_en.arb` | Localized onboarding/auth copy | Generated `AppL10n` keys | Global | No UI | ARB keys | None | Welcome, privacy, auth, OTP, restore, listening, shortcut verify, first transaction | None | Yes | N/A | Coverage is incomplete; many onboarding-adjacent screens still hardcode Arabic |
| `app/assets/logo/*`, `app/assets/brand/*`, `app/assets/flags/*`, `app/assets/brands/*` | Existing visual assets | Logo/brand/flags/brand SVGs | Used by onboarding country picker and logo components | Flags and logo assets | Asset bundle | None | N/A | Mali logo/brand PNGs, flags, real brand SVGs for Apple/Netflix/YouTube/Spotify | N/A | N/A | Use flags/logo if needed; avoid copyrighted service logos in new onboarding unless already approved and necessary |

## B. Current Onboarding Flow Map

1. App starts in `main.dart`, loads `AppSession`, opens database/catalog, then `MoneyApp` renders.
2. `_RizonSplashGate` overlays `_MaliSplash` for about 1400ms on top of whatever route is active.
3. `appRouter` redirects any non-onboarding route to `/onboarding` when `AppSession.status == needsOnboarding`.
4. `/onboarding` shows a 4-page `PageView`:
   - Welcome/value proposition.
   - How bank SMS becomes a transaction.
   - Privacy principles.
   - Country/base currency picker.
5. User can tap `Skip` on the first three pages to go directly to `/onboarding/auth`.
6. On the final onboarding page, CTA persists selected country/currency using `saveCountryCurrencyUseCaseProvider`, then goes to `/onboarding/auth`.
7. `/onboarding/auth` offers Apple, Google, email OTP, and two no-account/guest paths.
8. Apple/Google success calls `AppSession.setIdentity(...)`, then routes to `/onboarding/method`.
9. Email sends an OTP, routes to `/onboarding/otp`, verifies code, then routes to `/onboarding/method`.
10. Guest/no-account stores `auth_method = guest`, then routes to `/onboarding/method`.
11. `/onboarding/method` is a modal-style bottom sheet:
    - Android: explains sharing bank SMS to Mali, asks capture permission, then routes to `/onboarding/listening`.
    - iOS: shows Apple Shortcut guide and routes to `/onboarding/ios-verify`.
    - Both: shows AI consent toggle and a "later/add manually" option.
12. Before finishing capture setup, the method/listening/verify screens may check for remote backup if Supabase is configured. If found, the user is sent to `/onboarding/restore`.
13. Android `/onboarding/listening` starts capture listening if permitted and waits for `CaptureRuntime.confirmRequests`; user can paste manually or skip.
14. iOS `/onboarding/ios-verify` polls shared messages and lifecycle resume; user can paste manually, re-check setup, or skip.
15. If a transaction is captured or pasted, app routes to `/onboarding/first-transaction`.
16. First transaction:
    - Loading: circular loader.
    - Error or missing transaction: continue anyway.
    - Pending transaction: open confirmation sheet, then finish.
    - Confirmed transaction: show transaction card and continue.
17. `AppSession.finishOnboarding()` writes `onboarding_done = 1`, keeps `auth_method/auth_email`, and routes to `/`.

Saved:
- `onboarding_done`, `auth_method`, `auth_email` in secure storage.
- Country/base currency settings via user settings use case.
- AI consent via user settings repository.
- Backup state only if user uses backup flows.

Skipped:
- Intro pages can be skipped.
- Account can currently be skipped through guest paths.
- Capture setup can be skipped with "later/add manually" or "skip for now".
- First transaction proof can be skipped by finishing from listening/verify.

Required today:
- Nothing forces account creation in current code.
- Final onboarding completion only requires `finishOnboarding()`.
- Country has a default Saudi/SAR, so even country selection can effectively be left unchanged.

## C. Current States

- Loading:
  - Splash overlay timer.
  - OTP verify button spinner.
  - First transaction `txAsync.loading`.
  - Backup status loading.
  - Restore busy spinner.
- Empty:
  - Not explicit in onboarding; country list can become empty from search but has no empty state.
- Error:
  - Auth snackbar: "تعذر تسجيل الدخول الآن..."
  - OTP invalid field error.
  - Restore password/recovery-code errors.
  - First transaction error fallback.
  - Backup status error text.
- Success:
  - First transaction confirmed state.
  - Restore routes away after success.
  - Backup recovery code generation.
- Permission denied/granted:
  - `method_screen.dart` requests Android SMS permissions but does not branch UI for denied vs granted.
  - `sms_permission_screen.dart` is more of a share/manual explanation sheet than a runtime permission result surface.
- iOS setup incomplete:
  - `/onboarding/ios-verify` waiting state, re-check setup, paste fallback, skip.
- Backup enabled/disabled:
  - `BackupScreen` has guest gate, enabled state, disabled enable flow, recovery code state.
  - Onboarding restore appears only when remote backup is detected.
- Guest mode:
  - `auth_method == guest`; backup screen shows sign-in gate.
- Authenticated/unauthenticated:
  - Router status `needsOnboarding` vs `authenticated`.
  - Supabase session reconciliation signs out non-guest users if remote session disappears.

## D. Current UI Problems

- Flow clarity:
  - Current code allows guest/no-account entry, but the current design preference is email-first and required. Claude Design should not present guest as the preferred path unless the product owner asks.
  - Capture setup can be skipped before the user proves the app can capture transactions.
  - iOS setup is duplicated between the method sheet and the standalone shortcut screen.
- Missing expected screens:
  - No standalone first-run language selection screen.
  - No standalone DOB screen/field in current code, despite older docs mentioning DOB.
  - No dedicated backup explanation screen in first-run unless a remote backup is found.
  - No standalone Android SMS permission result screen in onboarding; permission states are not visually explained.
- Visual hierarchy:
  - Many pages use similar glass cards without a strong page-by-page story.
  - The intro preview is fake and visually disconnected from real app surfaces.
  - First transaction success is too quiet for a critical "aha" moment.
- Copy:
  - Arabic tone mixes Egyptian/Gulf/MSA.
  - English localization exists for many intro/auth strings but not all onboarding-adjacent screens.
  - Some important trust details are tiny or buried.
- Spacing/layout:
  - Method setup sheet is dense and scroll-heavy, especially iOS 8-step guide + AI consent.
  - Bottom sheets use inconsistent heights, radii, blur, and content density.
- Icons/assets:
  - Mixed Material and Lucide icon language.
  - Real service brand assets exist in repo but should not be used in onboarding unless explicitly justified.
- Trust/premium feel:
  - Privacy and backup are strong product differentiators but not given a premium, calming visual treatment.
  - AI consent explains sanitized text, but it feels like a settings toggle rather than a carefully designed trust moment.
- RTL/LTR:
  - Global locale handles direction, but several widgets use physical left/right paddings and manual direction wrappers.
  - Email/OTP/currency keywords need deliberate LTR islands inside RTL screens.
