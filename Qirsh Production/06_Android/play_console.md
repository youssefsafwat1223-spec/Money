# Google Play Console

## Create the app

<https://play.google.com/console> → **Create app** ($25 one-time registration)

| Field | Value |
|---|---|
| App name | Qirsh |
| Default language | Arabic |
| App or game | App |
| Free or paid | Free |

Package name `com.youssefsafwat.mali` is fixed by the first upload — it cannot
be changed afterwards.

## Play App Signing

Enrol when prompted (default for new apps). Google holds the app signing key;
your `mali-release.jks` becomes the **upload** key. Record both fingerprints from
Setup → App signing.

## Data safety — the section that gets apps rejected

App content → **Data safety**. Must agree with `docs/legal/PRIVACY_POLICY.md`.

Declare honestly:
- financial data is processed **on device**
- cloud sync is **off by default** and requires consent
- data is **encrypted in transit** and at rest locally
- users can **request deletion** (the app has an account-deletion path)

## ⚠️ SUPERSEDED — automatic SMS capture is REQUIRED for V1

This section previously described a share-only build and a notification-listener
declaration. Both were wrong:

- there has never been a `NotificationListenerService` in the Android app;
- `RECEIVE_SMS` was commented out, so the build shipped no SMS access at all.

Owner decision 2026-08-31 makes **automatic financial-SMS capture a required V1
feature**, published under the Play exception **SMS-based money management**.

**Publication is gated on an approved Play Permissions Declaration.**
See [`../18_Android_SMS_Capture/`](../18_Android_SMS_Capture/) for the
implementation, the declaration draft, the Data Safety draft and the device QA
matrix.

Permissions actually declared — minimal and defensible:

| Permission | Why |
|---|---|
| `INTERNET` | catalog sync, optional cloud features |
| `POST_NOTIFICATIONS` | budget alerts, capture confirmations |
| `USE_BIOMETRIC` | app lock |
| `RECEIVE_BOOT_COMPLETED` | restore scheduled reminders after reboot |
| `RECEIVE_SMS` | automatic bank-SMS capture — **restricted, needs Play approval** |

Note `RECEIVE_SMS` **not** `READ_SMS` — Qirsh receives new messages, it does not
read the user's message history. Say that; it is a meaningfully weaker ask.

No `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM` — deliberately avoided, as they are
Play-policy restricted.

## Store listing

- Short description (80 chars) and full description (4000), Arabic first
- Screenshots: phone required, tablet optional — real device, realistic Arabic
  data, **no real bank messages or account numbers**
- Feature graphic 1024×500
- App icon 512×512
- Privacy policy URL: `https://<host>/privacy`

## Internal testing

See `../09_Beta/play_internal_testing.md`.

## Production prerequisites

- [ ] Data safety complete and consistent with the policy
- [ ] Notification-listener use declared and justified
- [ ] Privacy policy URL resolves
- [ ] Store listing complete
- [ ] Content rating questionnaire done
- [ ] Signed AAB uploaded and processed
- [ ] Internal testing passed (`../09_Beta/`)
