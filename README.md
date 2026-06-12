# Mali (money_companion)

Arabic-first, on-device bank-SMS expense tracker. The Flutter app lives in [`app/`](app/).

This README documents building the **iOS IPA on Codemagic** (no Mac required) and
installing it on an iPhone with **Sideloadly / iLoader**.

---

## 1. Why Codemagic

You don't have a real Mac, but iOS builds need macOS + Xcode. Codemagic gives you a
cloud macOS runner that builds the `.ipa` for you. The repo ships a ready
[`codemagic.yaml`](codemagic.yaml) with two workflows:

| Workflow | Output | Needs Apple Developer Program? |
| --- | --- | --- |
| `ios-unsigned-sideload` | **Unsigned** `.ipa` for Sideloadly/iLoader | ❌ No (re-signed on install) |
| `ios-signed-release` | **Signed** `.ipa` (Ad Hoc / App Store) | ✅ Yes |

For your case (sideloading with a free Apple ID), use **`ios-unsigned-sideload`**.

---

## 2. Supabase configuration (optional — stub fallback)

The backend keys are passed at build time as Dart defines and read by
[`app/lib/core/backend/supabase_config.dart`](app/lib/core/backend/supabase_config.dart):

```dart
static const url     = String.fromEnvironment('SUPABASE_URL');
static const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
```

- **If you provide both** → real Supabase backend is used.
- **If you leave them empty/unset** → `isConfigured == false` → the app runs in
  **fallback stub mode** automatically. Nothing else to do.

The `codemagic.yaml` build commands already default them to `""`:

```bash
--dart-define=SUPABASE_URL="${SUPABASE_URL:-}" \
--dart-define=SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}"
```

To enable the real backend, set the two variables in a Codemagic **environment group**
named `supabase` (see step 4).

---

## 3. One-time Codemagic setup (manual steps in the Codemagic UI)

Do these **inside codemagic.io** — they cannot be scripted:

1. **Sign up / log in** at <https://codemagic.io> with your GitHub/GitLab/Bitbucket.
2. **Add application** → connect this repository. Codemagic auto-detects
   `codemagic.yaml` at the repo root.
3. **(Optional) Supabase variables**:
   - App settings → **Environment variables**.
   - Add `SUPABASE_URL` and `SUPABASE_ANON_KEY`.
   - Put both in a **group** named exactly `supabase` (matches `groups: [supabase]`
     in `codemagic.yaml`). Mark `SUPABASE_ANON_KEY` as **Secure**.
   - Skip this entirely to ship in stub mode.
4. **Email recipient**: edit the `recipients:` in `codemagic.yaml` to your email
   (currently `youssefsafwat1223@gmail.com`).
5. Pick the **`ios-unsigned-sideload`** workflow and press **Start new build**.

That's it for an unsigned build. (Signing setup is step 6, only for the signed workflow.)

---

## 4. Generating the IPA (unsigned, for sideloading)

1. Codemagic → your app → **Start new build** → workflow **`iOS Unsigned IPA (Sideload)`**.
2. The pipeline runs: `flutter pub get` → `gen-l10n` → `analyze` → `test` →
   `flutter build ios --release --no-codesign` → packages `Runner.app` into
   `money_companion-unsigned.ipa`.
3. When it finishes, download **`money_companion-unsigned.ipa`** from the build's
   **Artifacts** section (also emailed to you).

---

## 5. Installing the IPA on your iPhone

### Option A — Sideloadly (Windows/Mac)
1. Install Sideloadly: <https://sideloadly.io>.
2. Connect the iPhone via USB; trust the computer.
3. Drag `money_companion-unsigned.ipa` into Sideloadly.
4. Enter your **Apple ID** (a free account works). Sideloadly re-signs the app with
   a 7-day certificate and installs it.
5. On the iPhone: **Settings → General → VPN & Device Management** → trust your
   Apple ID developer profile.
6. Launch **Mali**.

> Free Apple IDs expire the app after **7 days** — just re-run Sideloadly to refresh.
> A paid Apple Developer account extends this to 1 year (use the signed workflow).

### Option B — iLoader
1. Open iLoader, connect the iPhone.
2. Load `money_companion-unsigned.ipa`, sign in with your Apple ID, install.
3. Trust the profile under **Settings → General → VPN & Device Management**.

---

## 6. Apple signing settings (only for `ios-signed-release`)

Required if you want a **signed** IPA (longer validity, TestFlight, Ad Hoc):

- **Apple Developer Program** membership (paid, $99/yr).
- An **App Store Connect API key** (Users and Access → Integrations → App Store
  Connect API → generate key). Upload it to Codemagic under
  **Teams → Integrations → App Store Connect** and name it `codemagic_asc_api_key`
  (matches `integrations.app_store_connect` in `codemagic.yaml`).
- **Bundle identifier** registered in your Apple Developer account:
  `com.example.moneyCompanion` (change in both Apple's portal and the workflow's
  `ios_signing.bundle_identifier` if you use your own).
- **Distribution type**: set `ios_signing.distribution_type` to one of
  `development` / `ad_hoc` / `app_store` / `enterprise` (currently `ad_hoc`).
- For **Ad Hoc**, register each test device's **UDID** in your Apple account so the
  provisioning profile includes it.
- The `xcode-project use-profiles` step + `--export-options-plist` handle profile
  selection automatically once the API key + bundle ID are in place.

### iOS extension targets (Share Extension + App Intents)
If you add the **`ShareBankMessage`** and **`BankMessageShortcuts`** targets
(see [`app/ios/SHORTCUT_SETUP.md`](app/ios/SHORTCUT_SETUP.md)), each is a separate
binary and needs its **own** bundle ID + provisioning profile, plus the shared
**App Group** `group.com.example.money_companion.shared` enabled on all three
targets under the same Team.

---

## 7. Required manual steps — exact checklist

**Inside Codemagic (UI):**
- [ ] Create account + **connect this repo**.
- [ ] (Optional) Add `SUPABASE_URL` / `SUPABASE_ANON_KEY` to a group named `supabase`.
- [ ] Set your email in `codemagic.yaml` `recipients:`.
- [ ] Run the **`ios-unsigned-sideload`** workflow.
- [ ] Download `money_companion-unsigned.ipa` from **Artifacts**.

**For the signed workflow only:**
- [ ] Buy/join the **Apple Developer Program**.
- [ ] Generate an **App Store Connect API key**, upload to Codemagic as
      `codemagic_asc_api_key`.
- [ ] Register the **bundle ID** (`com.example.moneyCompanion`) and test-device UDIDs.
- [ ] Run **`ios-signed-release`**, download the `.ipa` from `app/build/ios/ipa/`.

**On your iPhone:**
- [ ] Install the IPA via **Sideloadly** or **iLoader** with your Apple ID.
- [ ] **Trust** the developer profile in Settings → General → VPN & Device Management.

---

## 8. Building/running locally (Android / for reference)

```bash
cd app
flutter pub get
flutter gen-l10n
flutter analyze
flutter test
flutter run            # Android device/emulator (stub mode if no Supabase defines)
```

See [`app/README.md`](app/README.md) for architecture rules and
[`app/ios/SHORTCUT_SETUP.md`](app/ios/SHORTCUT_SETUP.md) for the iOS capture pipeline.
