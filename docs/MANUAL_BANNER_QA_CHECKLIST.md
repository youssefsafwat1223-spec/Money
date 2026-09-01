# Banner ads — physical device QA checklist

**Status: NOT EXECUTED. No physical device is available.** No Android device has
ever been attached to this machine, and iOS additionally needs Apple portal
access requiring a 2FA code from an unavailable client. Nothing below has been
run; none of it may be reported as passed.

Everything here is what widget tests structurally cannot cover: a real
`AdWidget` is a platform view, and a platform view does not exist in a Flutter
test.

## Setup

Debug/profile builds always use Google's test units — no console change needed
and no production traffic is possible. Register the device as a UMP test device
so the consent form can be exercised:

```
flutter run --dart-define=UMP_DEBUG_FORCE_EEA=true \
            --dart-define=UMP_DEBUG_TEST_DEVICE=<hashed-device-id>
```

Both flags must be ON in the flag service for the placement to appear.

## A. The placement itself

- [ ] The banner appears in the transactions list after the FIRST date section,
      with a date header visible below it.
- [ ] It never appears between two transaction rows of the same day.
- [ ] It never appears when the list has only one date section.
- [ ] It never appears on the pending-review filter.
- [ ] It never appears on the bills/subscriptions sub-tab.
- [ ] There is clear vertical space above and below; tapping the last row of the
      card above, and the first row below, never hits the ad.
- [ ] The "إعلان" / "Advertisement" label is visible directly above the creative.

## B. Layout stability — the thing tests cannot prove

- [ ] Scroll to the ad's position BEFORE it loads: content does not jump when it
      arrives. Record it in slow motion if unsure.
- [ ] Force a no-fill (airplane mode on, then open the tab): NO empty box, no
      grey placeholder, no gap where the ad would be.
- [ ] With the ad visible, nothing later collapses or resizes the slot.
- [ ] Rotate the device with the ad on screen: no overflow, no clipping, no
      horizontal scroll on the page body.
- [ ] Repeat A and B on the narrowest device available, and on a tablet.

## C. Offstage and coverage

- [ ] Open Settings, then Transactions: the ad requests only once visible
      (check with Ad Inspector or a proxy — a background tab must issue no
      request).
- [ ] Open a transaction detail sheet over the ad: the banner disappears and
      **does not bleed over the sheet**. This is the single most important
      check on this page — `AdWidget` is a platform view, and platform views
      have bled over Flutter modals in this app before.
- [ ] Close the sheet: the banner returns without a new request inside 30s.
- [ ] Push a full route (e.g. `/settings/…`) and return: same.
- [ ] Flick between tabs rapidly ~10 times: exactly one request in 30 seconds.

## D. Gates

- [ ] `enable_banner_ads` OFF: no ad, no request, no space.
- [ ] Master ON, `enable_banner_transactions_list` OFF: same.
- [ ] Flip a flag remotely mid-session, background and resume: the change takes
      effect without a reinstall.
- [ ] An account with an ACTIVE ad-free entitlement: no ad, no request, no
      space, and no gap where one would be.
- [ ] Airplane mode: the transactions list works normally.
- [ ] Decline UMP consent: no ad, no request; the app is unaffected.
- [ ] Revoke consent from Settings → ad privacy options, then return: no ad.

## E. Accessibility and RTL

- [ ] Arabic (RTL): label centred, ad centred, no mirrored clipping.
- [ ] English (LTR): the same.
- [ ] Largest system font size: the label does not overflow or overlap the ad.
- [ ] VoiceOver / TalkBack: the ad is reachable and announced; it is not
      confused with a transaction row.
- [ ] Devices with a notch/home indicator: no overlap with safe areas or the
      bottom nav.

## F. Ad Inspector

- [ ] Open the Ad Inspector (shake gesture on a test device) and confirm: the
      request is for the expected TEST unit, is non-personalized, and there is
      exactly one banner request per screen entry.

## G. Interstitial regression

The SDK initializer moved into a shared file, so re-verify the existing format:

- [ ] Report export still shows the interstitial once, and the report still
      generates whether the ad shows, fails or is dismissed.
- [ ] The report still generates with ads flagged off.
