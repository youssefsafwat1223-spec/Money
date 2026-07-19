# Client Release Checklist

Short, actionable steps remaining to generate and hand over the client build. See `docs/FINAL_RELEASE_READINESS_AUDIT.md` for the full findings behind each item.

## Before building

- [ ] Review `docs/FINAL_RELEASE_READINESS_AUDIT.md` and this session's diff, then approve a commit for the fixes listed there (18 files — no commit has been made yet).
- [ ] Decide whether to clean up the 2 stray screenshot PNGs + `prototype_onboarding_2024.html` at the `app/` repo root before committing.
- [ ] Confirm the privacy policy's language about AI/cloud processing being "optional" matches the app's current always-on behavior (no in-app toggle exists) — update copy if it doesn't.

## iOS

- [ ] Have a paid Apple Developer Program membership connected (required for a signed build; not available in the dev environment used for this audit).
- [ ] Run `flutter build ios --release` (or trigger the `ios-signed-release` Codemagic workflow once Apple credentials are wired into Codemagic settings).
- [ ] If sideloading instead of App Store: use the existing `ios-unsigned-sideload` Codemagic workflow — no paid account needed.
- [ ] Do a final tap-through on a real device or fresh simulator before shipping (launch → onboarding → sign-in → capture a test SMS → confirm it appears on the dashboard).

## Android

- [ ] Install the Android SDK (this audit's environment had none — Android could only be source-reviewed, not built or run). On any machine with Android Studio / the SDK installed:
  - [ ] `flutter build apk --debug` — confirm it succeeds.
  - [ ] Generate a release keystore if one doesn't exist yet (see `docs/ANDROID_RELEASE_SIGNING.md`), then set `android/key.properties` or the 4 `ANDROID_KEYSTORE_*` environment variables.
  - [ ] `flutter build appbundle --release` — this fails loudly if signing isn't configured (by design), so a clean pass confirms signing is correct.
- [ ] Do a final tap-through on a real device or emulator before shipping.

## Supabase

- [ ] Confirm `supabase migration list --linked` shows local and remote in sync (0001–0054 as of this audit).
- [ ] Deploy the 2 Edge Functions changed this session: `supabase functions deploy bank-discovery` and `supabase functions deploy parse-sms`.
- [ ] Confirm required secrets are set (presence only, never print values): `GEMINI_API_KEY`, `APNS_KEY_ID`/`APNS_TEAM_ID`/`APNS_BUNDLE_ID`/`APNS_PRIVATE_KEY`, `NOTIFICATION_RETRY_WORKER_SECRET`, `PURGE_WORKER_SECRET`.
- [ ] Decide how `purge-scheduled-deletions` gets invoked on a recurring schedule (it is deliberately not `pg_cron`-wired yet — see `docs/USER_DELETION_DECISION_BRIEF.md`). Until this is decided, someone needs to trigger it manually or via an external scheduler for scheduled account deletions to actually complete.
- [ ] Optional but recommended: set an explicit Sentry `environment` tag (dev/staging/prod) so crash reports can be filtered by build type — currently every build reports under the same untagged environment.

## Final handoff

- [ ] Hand the signed iOS build (IPA or TestFlight link) and signed Android build (APK or AAB) to the client.
- [ ] Confirm the client knows the account-deletion grace period (30 days) and how to reach support to cancel a pending deletion, if that's part of their onboarding to the app.
