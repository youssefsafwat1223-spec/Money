# AdMob Setup Checklist

Owner: **Youssef**. Blocks nothing — the app ships without it.
Do this when you want ads live, not before store submission.

## 1 — Account

- [ ] Create or sign in to an AdMob account (admob.google.com) with the same
      Google account that owns the Play Console listing.
- [ ] Link AdMob to that Play Console account.
- [ ] Complete payments/tax setup. **Ads will not serve until this is done** —
      this is the step most often forgotten, and it fails silently: the SDK
      requests an ad, gets no fill, and the report just generates without one.

## 2 — Register the two apps

AdMob treats iOS and Android as separate apps. Register both.

- [ ] **iOS app** → record its **App ID** (`ca-app-pub-…~…`)
- [ ] **Android app** → record its **App ID** (`ca-app-pub-…~…`)

Bundle / package identifier for both: `com.youssefsafwat.mali`
(the technical identifier is not rebranded — see the app CLAUDE.md).

If the app is not on the store yet, register it as "not listed yet" and link it
after publication.

## 3 — Create one interstitial ad unit per platform

The app uses exactly one placement: the **report-export interstitial**.

- [ ] iOS → **Interstitial** ad unit → record its **Ad unit ID** (`ca-app-pub-…/…`)
- [ ] Android → **Interstitial** ad unit → record its **Ad unit ID** (`ca-app-pub-…/…`)

Do **not** create rewarded units. Rewarded ads are forbidden in this codebase and
an architecture test fails if the concept appears anywhere in `lib/`.

## 4 — Sanity-check the four values before entering them

- [ ] Both **App IDs** contain `~`
- [ ] Both **Ad unit IDs** contain `/`
- [ ] None begins with `ca-app-pub-3940256099942544` (that is Google's TEST
      publisher — a release supplying it is treated as unconfigured)
- [ ] Each matches `ca-app-pub-` + 16 digits + separator + 10 digits

A malformed **Android App ID fails the build**, by design. A malformed ad unit ID
does not fail the build — it silently means "no ads". Check both.

## 5 — Set them in Codemagic

In the **`supabase`** variable group:

- [ ] `ADMOB_APP_ID_IOS`
- [ ] `ADMOB_APP_ID_ANDROID`
- [ ] `ADMOB_INTERSTITIAL_IOS`
- [ ] `ADMOB_INTERSTITIAL_ANDROID`

Not marked secret — they are deployment configuration, not credentials. Never
commit them.

## 6 — Verify

Follow [`verification.md`](verification.md). Do not assume it works because the
build succeeded: an absent or incomplete configuration builds perfectly and
ships with ads off.

## 7 — Store declarations

- [ ] Play Console → Ads → declare **"Yes, my app contains ads"**
- [ ] App Store Connect → declare advertising identifier usage.
      V1 requests **no IDFA / ATT prompt**; iOS declares one `SKAdNetworkIdentifier`
      (`cstr6suwn9.skadnetwork`) in `Info.plist`.
- [ ] Confirm the privacy policy's third-party section still matches what ships
      (`docs/legal/PRIVACY_POLICY.md` §7). A test asserts the policy matches
      actual behaviour, so if ads change what leaves the device, that section
      changes too.
