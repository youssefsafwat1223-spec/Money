# Android SMS Capture Decision

Status: intentionally disabled for MVP.

Qirsh currently supports Android local/manual entry and Android text share/import flows. Direct Android SMS capture is not wired:

- `android_sms_capture_service.dart` does not request SMS permissions.
- `sms_background_handler.dart` is a no-op.
- `AndroidManifest.xml` does not declare `READ_SMS`, `RECEIVE_SMS`, or an SMS broadcast receiver.

This is intentional until there is explicit approval for a Google Play policy review. Android SMS permissions are sensitive permissions and should not be added unless the app qualifies for an allowed SMS use case and the store listing, privacy policy, and runtime disclosure are ready.

Do not add Android SMS permissions as part of sync, iOS capture, or local database work. Restoring Android SMS capture should be a separate approved task with:

- Google Play SMS/Call Log permission policy review.
- Clear user-facing disclosure and opt-in.
- A minimal receiver/service implementation.
- Tests proving local Drift import does not duplicate iOS/share/manual flows.
