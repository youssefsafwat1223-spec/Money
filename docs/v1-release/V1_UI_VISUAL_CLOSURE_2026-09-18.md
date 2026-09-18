# V1 UI Visual Closure — 2026-09-18

Closes §6 of `V1_UI_ACCEPTANCE_MATRIX_VISUAL_2026-09-17.md`, which named twelve
shipping surfaces it had never opened, and reconciles the denominator that
document reported against.

> **AMENDED 2026-09-18 (later).** Settings → Language shipped after this pass,
> which adds one surface to the denominator (**58**) and closes §5's open item.
> The amendments are §1a and §5a; the sections they amend are left as written.

---

## 0. The contradiction, and what caused it

The 2026-09-17 report said **"VISUALLY INSPECTED: 45 — every one"** and, four
paragraphs later, **"12 surfaces were not inspected."** Both sentences were
true. "Every one" meant every one of the 45 it had chosen to inspect, and 45
was its denominator. A surface that was never opened could not appear in a
count derived from the surfaces that were.

That is the whole mechanism, and it is worth stating plainly because it is the
kind of arithmetic that reads as completeness. **A denominator built from what
was inspected can never show what was missed.** The denominator below is the
Atlas manifest — an inventory built before this pass, from the source, without
reference to what anyone had looked at.

Reconstructed for 2026-09-17, its numbers should have read:

| | |
|---|---|
| Total shipping unique surfaces | **57** |
| Visually inspected | 45 |
| **Not inspected** | **12** |
| Mismatch | 0 of the 45 |

§6 was itself incomplete. It listed twelve screens and four overlays. It did
not list **13 further overlay designs** or **9 further dialog designs** that
the Atlas enumerates, nor two shipping routes — `SmsPermissionScreen`
(`/capture/sms-permission`) and `PlanningCurrencyRepairScreen`
(`/settings/planning-currency-repair`, 9 call sites) — which appear in neither
the 19-route walk nor §6's list of what was missing. They were not inspected
and not recorded as uninspected.

---

## 1. Counts

Denominator: the HTML prototype's `REQUIRED_IDS` manifest — 99 frames (screen
states), 27 overlay designs, 11 dialog designs — reduced to unique surfaces.

| | |
|---|---|
| **TOTAL SHIPPING UNIQUE SURFACES** | **57** |
| **VISUALLY INSPECTED** | **57** |
| **NOT INSPECTED** | **0** |
| **MATCH** | **48** |
| **ACCEPTABLE INTENTIONAL DELTA** | **9** |
| **MISMATCH** | **0** — 7 found, 7 fixed and verified |
| **NOT APPLICABLE** | **3** |

Beyond the 57: **13 overlay designs and 9 dialog designs** the Atlas lists and
neither pass has opened. They are enumerated in §6 rather than folded into the
total, because folding them in is exactly the move that produced the original
contradiction.

### 1a. Amended after Settings → Language shipped

| | |
|---|---|
| **TOTAL SHIPPING UNIQUE SURFACES** | **58** |
| **VISUALLY INSPECTED** | **58** |
| **NOT INSPECTED** | **0** |
| **MATCH** | **49** |
| **ACCEPTABLE INTENTIONAL DELTA** | **9** |
| **MISMATCH** | **0** — 7 found, 7 fixed and verified |
| **NOT APPLICABLE** | **3** |

The 58th is the **language picker** — `Settings → Language`, a
`_showSettingsPicker` sheet offering العربية and English as endonyms. It has no
Atlas design to compare against, because the Atlas was drawn for an app that had
no such control; it is classified **MATCH** against the pattern it is built
from, which is the same sheet the Country and Currency rows have used since the
Atlas was measured — same `RadioListTile`, same navy sheet theme, same
`showDragHandle`, same title typography. A new control that looks exactly like
its two neighbours is the correct outcome here, and the deviation worth
flagging would have been a new one.

Captured on device in both languages by the `ui` phase of
`tool/language_restart_proof.sh`, which leaves the picker open over the settings
list: `~/.qirsh-qa/language-restart-proof/language-en.png` (LTR, «English»
selected) and `…/language-ar.png` (mirrored RTL, «العربية» selected), each over
a settings screen rendering entirely in its own language.

The same run also produced the first photograph of the **native unlock prompt**
this programme has managed — `applock-native-prompt-en.png` and
`applock-native-prompt-ar.png`, iOS's own passcode sheet with the app's string
inside it, one per language. See §5a.

The 22 further Atlas overlay and dialog designs in §6 remain outside the
denominator and remain uninspected.

Evidence: `~/.qirsh-qa/visual-closure-2026-09-17/` — **155 captures** across
`vc/ vc-verify/ onb/ onb-verify5/ boot2/ dlg/ dlg-verify/ applock/`. Device:
iPhone 17 Pro Max, iOS 26.5, 1320×2868, 16-bit RGBA.

---

## 2. The twelve, closed

| Surface | Atlas ID | Reached by | AR | EN | Verdict |
|---|---|---|---|---|---|
| `OnboardingStoryScreen` p1 | `ONBOARDING-ONBOARDINGSTORY-DEFAULT` | signed-out, welcome gate cleared | ✔ | ✔ | MISMATCH → fixed |
| `OnboardingStoryScreen` p2 | `…-PAGE2` | its own CTA | ✔ | ✔ | MISMATCH → fixed |
| `OnboardingBrandScreen` | `ONBOARDING-ONBOARDINGBRAND-DEFAULT` | story CTA | ✔ | ✔ | MATCH |
| `OnboardingAuthScreen` | `ONBOARDING-ONBOARDINGAUTH-DEFAULT` | brand CTA | ✔ | ✔ | MATCH |
| `OnboardingSetupScreen` step 1 | `ONBOARDING-ONBOARDINGSETUP-DEFAULT` | route | ✔ | ✔ | MISMATCH → fixed |
| `OnboardingSetupScreen` step 2 | — | country chosen | ✔ | ✔ | MATCH |
| `StartupLoadingScreen` | `SHELL-STARTUPLOADING-DEFAULT` | live cold start + injected runner | ✔ | ✔ | MATCH |
| `StartupLoadingScreen(error:)` | `SHELL-STARTUPLOADING-ERROR` | injected failing runner | ✔ | ✔ | MATCH |
| `AppBootLoader` | `SHELL-RESTORING` | `appDataRestoring` | ✔ | ✔ | MISMATCH → fixed |
| `ForceUpdateScreen` | `ONBOARDING-FORCEUPDATE-DEFAULT` | local force-update row | ✔ | ✔ | MISMATCH → fixed |
| `AppLockGate` | `SHELL-APPLOCK-DEFAULT` | armed flag, prompt read off the platform channel | ✔ | ✔ | MATCH — see §5 |
| `_DatabaseRecoveryView` | `SHELL-DATABASE-RECOVERY` | injected `database_open` failure | ✔ | ✔ | MISMATCH → fixed |
| `ReportPreviewScreen` | `REPORTING-REPORTPREVIEW-DEFAULT` | real generation | ✔ | ✔ | MATCH |
| `PlansScreen` | `PLANS-PLANS-EMPTY` | settings row | ✔ | ✔ | DELTA |
| `MerchantOffersScreen` | `COUPONS-MERCHANTOFFERS-EMPTY` | route | ✔ | ✔ | MATCH |

And the four §6 called "unexercised":

| Surface | Reached by | Verdict |
|---|---|---|
| `OVL-ACCOUNT-FORM` | the add-account button | MISMATCH → fixed |
| `OVL-CARD-FORM` | the add-card button | MISMATCH → fixed |
| `OVL-BILL-DETAIL` | a bill written through the shipping repository | MATCH |
| `OVL-PLANNING-CONFLICTS` populated | still empty-only | see §6 |

Plus three dialog designs beyond `DLG-DESTRUCTIVE-CONFIRM`:
`DLG-REPORT-PROGRESS`, `DLG-UNSYNCED-WARNING` (AR only — it needs a dirty
outbox at sign-out, which only the destructive run produces),
`DLG-DATE-PICKER` (MISMATCH → fixed).

§6's claim that `OVL-ACCOUNT-FORM` and `OVL-CARD-FORM` "take a `WidgetRef`,
which this walk has no honest way to synthesise" was true and beside the point:
neither needs a synthesised ref, because `/accounts` and `/cards` each carry a
button that supplies a real one. Both sheets held a defect.

---

## 3. The seven mismatches

| # | Surface | Defect | State |
|---|---|---|---|
| 1 | `ForceUpdateScreen` | English users got Arabic title, body and CTA — the two captures were **byte-identical**. Blocks the whole app | fixed, verified |
| 2 | `OVL-ACCOUNT-FORM` | currency dropdown read **"SAR — SAR"** | fixed, verified |
| 3 | `OVL-CARD-FORM` | Network dropdown read «بطاقة» in English; same string leaked into the account-detail card row | fixed, verified |
| 4 | `SHELL-RESTORING` | caption «جارٍ تجهيز التطبيق...» under English | fixed, verified |
| 5 | welcome story | `TextAlign.right` + `Positioned(left:)`; the halftone ran through English body copy | fixed, verified |
| 6 | setup country selector | **white text on white pills, both languages**, 1.00:1 | fixed, verified 11.55:1 |
| 7 | `DLG-DATE-PICKER` | a fully Arabic calendar over an English app | fixed, verified |

An eighth was reported on 2026-09-17 — the app-lock prompt — and was **not a
mismatch**. It is corrected in §5.

All seven fixes were verified by re-capture. For (1) and (7), the **Arabic capture
is byte-identical before and after** and only the English one moved, which is
the signature a locale fix should leave.

**(6) is the most serious.** It is not a localization bug: on the mandatory
first-run setup step, in Arabic and English alike, a new user could read
exactly one country — the one already selected. It survived because the screen
had never been opened; §6 recorded it as "covered by widget tests".

---

## 4. Three ways this pass produced evidence that looked like coverage

Recorded because each one would have been filed as a surface inspected, and the
first two were caught only by accident.

1. **13 captures, one frame.** A verification run reported 13 successful
   captures and wrote 13 **byte-identical** PNGs of the iOS launch screen. The
   walk had genuinely run — it found the country chips, tapped them, advanced a
   step — but the device had stopped presenting the Flutter view. Nothing in
   the log said so. `tool/check_captures.py` now rejects a run whose captures
   are all one frame, and flags identical AR/EN pairs, which is how (1) in §3
   announces itself.

2. **Four captures, one boot state.** `StartupApp` assigns its runner in
   `initState` as `late final`, so pumping a second `StartupApp` of the same
   type reused the `State` and kept the first runner. Four variants rendered
   the same loading screen, byte-distinct because the spinner had moved. Fixed
   with a unique key per variant.

3. **Three property-level fixes that never painted.** The country chips were
   fixed three times — per-chip `backgroundColor`, per-chip `color`, an
   ancestor `ChipTheme`. Each resolves correctly in a widget test that pumps
   the **real screen** and reads the chip's `Ink`, reporting `white @ 10%`.
   Each still landed `rgb(255,255,255)` on the device. Material's chip paints
   its own surface from the ambient theme *underneath* the `Ink`. Reading the
   property proved nothing three times running.

A fourth, in the tests rather than the captures: the first `localeProvider`
regression test **passed against the broken provider**. `maybeWhen` already
defaults `skipLoadingOnRefresh` to true, so the reload case it tested was never
broken. The case that was broken is an **error**, and the test now fails on the
old provider and passes on the new one.

`tool/png_sample.py` exists for the same reason. It was written after a
downscaled screenshot nearly produced a false finding — two auth-screen trust
badges that looked like missing glyphs and were real icons at full size — and
its own first version reported the navy page background as **yellow**, because
Simulator captures are 16-bit RGBA and an 8-bit reader returns garbage
silently.

---

## 5. The app-lock prompt — a finding I got wrong, and what is actually there

**There is no mismatch in the gate.** Measured on the real `AppLockGate`, with
the real keychain flag, the real 30-second background delay and the real
lifecycle transition:

| persisted | app resolved | prompt handed to iOS |
|---|---|---|
| `ar` | `ar` | Arabic only (`ar=true en=false`) |
| `en` | `en` | **English only** (`ar=false en=true`) |

`"Unlock Qirsh to protect your financial data."` is what iOS gets when the app
is in English. The gate composes the prompt from the app's language and always
did.

### Why the earlier report said otherwise

The 2026-09-17 closure reported this surface as an outstanding mismatch on the
strength of a host screenshot showing an Arabic prompt. That screenshot was
taken against a data container that held **no persisted settings at all** —
verified afterwards: the container had been recreated and its `Documents`
directory was empty. The app was therefore in its default language, and the
Arabic prompt was correct behaviour. The screenshot proved nothing, and the
finding derived from it was wrong.

Two things made the mistake easy to keep. The prompt cannot be photographed
from inside a test, and the reason given for that was also wrong: it is not the
native sheet that freezes the run, it is the `paused` lifecycle state —
`tester.pump()` after it never returns because frame production has stopped.
And re-running `app.main()` does not re-arm the gate, because its `State` is
reused and `initState` never fires again; a run that looked like a cold start
sat on the dashboard with the lock armed.

### How it is measured now

`integration_test/applock_prompt_language_test.dart` reads the string off the
`local_auth` pigeon channel, which is the string iOS renders verbatim. The mock
declines to reply; pigeon raises a connection error; `AppLockService` catches it
and reports a failed authentication, so **the gate stays locked**. Nothing about
the gate, the flag, the delay or the lifecycle is stubbed — only the platform
call at the very end, and only to read what it was given. Both languages are
asserted, each required to carry its own prompt and not the other's.

No production code was changed for this surface. The change written during the
earlier pass — making the gate await settings before prompting — was reverted
and is not needed.

### The real finding underneath it

While establishing the reproduction, something else turned up that is worth
more than the thing I was asked to fix:

**A language written in one process reads back as Arabic in the next.**
Measured twice, with nothing running in between:

```
flutter test integration_test/applock_arm_test.dart -d <udid> \
  --dart-define=QIRSH_APPLOCK_LANG=en          → PERSISTED language=en
flutter test integration_test/applock_arm_test.dart -d <udid> \
  --dart-define=QIRSH_APPLOCK_VERIFY=1         → PERSISTED language=ar
```

If that reproduces through the app's own settings screen, an English user's app
comes up Arabic after every restart — and the Arabic unlock prompt reported on
2026-09-17 was a symptom of it rather than a defect of the gate. It would affect
every surface in the app, not this one.

It is **not** a UI visual-fidelity defect and I did not investigate the
mechanism or attempt a fix: the instruction for this pass was not to reopen
other engineering scope. It is recorded here, with its reproduction, as the
highest-value open item this programme has produced.

---

### 5a. Amended — the prompt WAS wrong on a cold start, and is now fixed

§5 above says "there is no mismatch in the gate". That is wrong, and the way it
is wrong is worth keeping: the measurement it rests on backgrounded and resumed
a running app, by which point the app had long since read its language out of
the database. **That test could not see the defect it was clearing.**

On a genuine cold start, with English persisted, the gate did hand iOS the
Arabic string:

```
persisted=en resolved=en promptSeen=true promptAr=true promptEn=false
```

`AppLockGate` raises the prompt from a post-frame callback on the FIRST frame —
deliberately, so nothing protected is ever on screen unauthenticated. At that
instant the SQLCipher database has not been opened, so `context.l10n` is still
the app default whatever the user persisted. iOS is handed that string once, by
value, and draws it.

It was left unfixed at the time on the grounds that no V1 user could reach it —
`SaveLanguageUseCase` had no callers, so every user's persisted language WAS the
default. Settings → Language removes that grounds, which is why the fix shipped
with it rather than after it.

**The fix:** `core/security/lock_prompt_language.dart`, a keychain mirror of
`user_settings.language` written by every path that writes the column, in the
same await chain as the write. The gate reads it — one local keychain read, no
database, no provider, no network, no bootstrap — while the lock screen is
already up, so it opens no window and changes no authentication behaviour.

An earlier attempt cached the same value from a Riverpod provider. It passed
once and failed on the next run, because "when a provider runs" is not orderable
against the process ending; it was reverted rather than shipped. The difference
is the write site, not the storage.

`test/core/security/app_lock_prompt_language_test.dart` pins the ambient locale
to Arabic and the mirror to English — the exact cold-start shape — and **fails
against the pre-fix gate** with `Expected: 'Unlock Qirsh…' Actual: 'افتح قِرش…'`.
The device half is the `verify` phase of `tool/language_restart_proof.sh`, which
reads the string off the `local_auth` pigeon channel on a real cold start of an
install it never reinstalls.

### 5b. Amended — the persistence finding was the installer

§5's "real finding underneath it" — a language written in one process reading
back as Arabic in the next — **is closed as a harness artifact**. `flutter test`
uninstalls the app when it finishes, and iOS destroys the data container on
uninstall, so the "next process" opened a brand-new database whose settings row
had just been created with its hardcoded default. The value never failed to
persist; the file it lived in had been deleted. Full account and the
same-install proof: `V1_LANGUAGE_PERSISTENCE_INVESTIGATION.md`.

---

## 6. Still not inspected — stated, not absorbed

Excluded from the 57 above rather than hidden inside it.

**13 overlay designs** the Atlas lists and no pass has opened:
`OVL-ACCOUNT-DELETE`, `OVL-BANK-DISCOVERY`, `OVL-CARD-ATTACH-EXISTING`,
`OVL-PASTE-BATCH-RESULTS`, `OVL-PLAN-DETAIL`, `OVL-PLAN-LINK-TRANSACTION`,
`OVL-SETTINGS-CATEGORY-FORM`, `OVL-SETTINGS-INFO`, `OVL-SETTINGS-PROFILE-TEXT`,
`OVL-SETTINGS-QUIET-HOURS`, `OVL-SMART-INBOX`, `OVL-SUSPECTED-DUPLICATES`,
`OVL-TX-FILTER`.

**8 dialog designs**: `DLG-BULK-CONFIRM`, `DLG-DISMISS-DUPES`,
`DLG-REPLACE-CONFIRM`, `DLG-RESTORE-CONFIRM`, `DLG-TIME-PICKER`,
`DLG-VALUE-INPUT`, and `DLG-SMS-DISCLOSURE` (Android only — N/A on iOS).
Four were attempted and reported "no data to render" by the walk: the QA ledger
holds no pending capture, no suspected duplicate, and every recent transaction
already carries a value.

**2 shipping routes** neither pass has visited, and which §6 never listed:
`SmsPermissionScreen` and `PlanningCurrencyRepairScreen`.

**`OnboardingSetupScreen` step 3** (the shortcut guide) and
**`ONBOARDING-PERMISSION-PROMPT`**: tapping "Enable" asks iOS for notification
permission, and while that native alert is up the engine stops delivering
vsync — `tester.pump()` never returns and the run freezes, discarding every
capture taken so far. The shipping `entry: captureGuide` path reaches step 3
and is wired into the harness but has not yet been run.

**`OVL-PLANNING-CONFLICTS` populated**: inspected empty only; the QA ledger has
no conflicts.

---

## 7. Acceptable intentional deltas — 9

The four from 2026-09-17 stand. Five added:

| | |
|---|---|
| 5.5 `PlansScreen` empty state | the shared `AppEmptyState`, not the prototype's bespoke illustration. The Atlas records the app's class as **A — shared AppEmptyState** and asked the prototype to invent a dedicated frame; the prototype drew one. The app is consistent with every other empty state |
| 5.6 `MerchantOffersScreen` | the empty state IS the V1 appearance — `enable_coupons` ships off and the catalog holds 0 merchants |
| 5.7 `_DatabaseRecoveryView` background | black with a bare icon, where its sibling boot screens use the page background and an icon tile. Deliberate and commented in the source; only the destructive CTA colour was changed |
| 5.8 App display name | `Enter iPhone Passcode for "قرش"` — the Arabic brand name in an English UI |
| 5.9 Message-centre notification rows | Arabic rows in an English centre. This is §5.1 (stored notification text keeps its delivery language) now confirmed on screen rather than asserted |

---

## 8. Findings NOT fixed, reported

* **The persisted language may not survive a process restart** — §5. Outside
  the visual scope, and larger than it.
* **`notification_journey_service.dart:114-134`** composes campaign
  notifications from `titleAr`/`bodyAr` unconditionally, so an English user
  would *receive* an Arabic notification. Same family as §3 (1), but a
  notification is not a visual surface and the fix needs the
  `notificationLanguage` pattern rather than a context. Out of scope for a
  visual pass; flagged rather than silently widened into one.
* **Dashboard metric trio** renders `−0.00` for a zero "Spent today". Cosmetic,
  pre-existing, on a surface accepted in the previous pass.

---

## 9. Guards added

Each verified to fail on the defect and pass on the fix.

| Test | Pins |
|---|---|
| `no_handwritten_currency_pair_test` | no file pairs a currency code with its own label by hand |
| `no_arabic_only_server_copy_test` | no widget reads `titleAr`/`bodyAr`/`actionLabelAr`; no hardcoded `TextAlign.right`/`left`; no picker pins its own locale; the story keeps `PositionedDirectional` |
| `locale_holds_across_reload_test` | a settings **error** does not switch an English reader's app to Arabic |
| `country_pill_contrast_test` | the country selector does not use a themed Material chip |
| `applock_prompt_language_test` | the unlock prompt iOS is handed carries the app's language, in both directions, on the real gate |

`tool/png_sample.py` and `tool/check_captures.py` are the two measurement tools
this pass needed and did not have.

---

## 10. Verdict

**NOT INSPECTED = 0** against the reconciled 57-surface denominator, and the 22
further Atlas overlay and dialog designs outside it are enumerated in §6 rather
than absorbed.

**MISMATCH = 0.** Seven were found and all seven are fixed and verified by
re-capture. The eighth — the app-lock prompt — was never a mismatch: it was
measured against a container with no persisted settings, and the gate hands iOS
the correct language in both cases (§5). That correction is the honest outcome,
not a reconciliation: the surface now has a passing two-language assertion
behind it where before it had a screenshot of an app in its default language.

One open item was carried out of this pass rather than closed by it: a language
written in one process read back as Arabic in the next (§5). It has since been
investigated and closed as a harness artifact — see §5b.

4,034 tests pass. Analyzer clean across `lib`, `test`, `integration_test`.

### Amended verdict — 2026-09-18, after Settings → Language

**58 / 58 / 0 / 0.** The denominator gains the language picker (§1a). §5's
clearance of the app-lock prompt is withdrawn: the prompt WAS wrong on a cold
start, it is fixed, and the fix has a test that fails against the old gate
(§5a). §5's open persistence finding is closed as a harness artifact (§5b).

4,046 tests pass, 2 skipped. Analyzer clean across `lib`, `test`,
`integration_test`.
