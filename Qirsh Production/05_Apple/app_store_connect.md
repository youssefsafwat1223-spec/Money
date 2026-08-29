# App Store Connect

## Create the app record

<https://appstoreconnect.apple.com> → My Apps → **+** → New App

| Field | Value |
|---|---|
| Platform | iOS |
| Name | Qirsh (or قرش) |
| Primary language | Arabic |
| Bundle ID | `com.youssefsafwat.mali` |
| SKU | any internal id, e.g. `qirsh-ios-001` |
| User access | Full |

The bundle ID must already exist as an App ID (see `apple_developer.md`).

## App Privacy — must match the policy

App Privacy → Get Started. Answers must agree with
`docs/legal/PRIVACY_POLICY.md`. Where cloud sync is off by default and financial
data is local, say so — do not over-declare collection that does not happen, and
do not under-declare what sync does when enabled.

Declare the privacy policy URL: `https://<host>/privacy` — **must resolve before
submission.**

## App Information

- Category: Finance
- Age rating: complete the questionnaire (no objectionable content)
- Support URL and marketing URL — the legal site host works

## Screenshots

Required: 6.7" and 6.5" iPhone. Take them on a real device with realistic Arabic
data, not lorem values.

**Do not screenshot real bank messages or real account numbers.**

## Build upload

Codemagic `ios-signed-release`, or Xcode Organizer → Distribute App → App Store
Connect. Processing takes 10–60 minutes.

## TestFlight

See `../09_Beta/testflight.md`.

## Review information

- Demo account credentials — reviewers cannot receive real bank SMS
- Notes: explain that Qirsh reads bank notifications **on device** to build the
  user's own spending record, that cloud sync is off by default, and that the
  AI classifier runs locally
- Contact details

## Submission

Only after §11 exit criteria. Phased release (7-day ramp) is recommended.
