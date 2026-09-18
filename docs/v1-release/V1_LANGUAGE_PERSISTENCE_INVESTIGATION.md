# Language Persistence — investigation and resolution, 2026-09-18

Investigating the finding raised at the end of the UI closure pass: *"a language
written in one process reads back as Arabic in the next."*

Three things came out of it. The first closes the finding. The second corrects a
retraction I made. The third is the fact both of them were standing on, and it
is the one that needs an owner decision.

> **AMENDED 2026-09-18 (later).** The owner took that decision: English was a
> V1 contract requirement shipping unreachable, so **Settings → Language**
> shipped. That makes the cold-start prompt defect in §2 reachable, so it was
> fixed in the same change. §2's "not a V1 defect" and §3's "OPEN — owner
> decision" are both superseded by **§6**, which carries the device evidence.
> The sections they amend are left as written.

---

## 1. The persistence finding was a harness artifact — CLOSED

**`flutter test` uninstalls the app when it finishes.** iOS destroys the data
container on uninstall, so the "next process" opened a brand-new database whose
`user_settings` row had just been created with its hardcoded default of `'ar'`.
The value never failed to persist; the file it lived in had been deleted.

Proof it was gone rather than reverted:

```
xcrun simctl listapps <device> | grep -c com.youssefsafwat.mali   → 0
xcrun simctl get_app_container <device> <bundle> data            → No such file or directory
```

`tool/process_restart_proof.sh` says this in its own header, and was in this
repo before the mistake was made:

> Why not `flutter test`: it reinstalls the app on every invocation, and iOS
> replaces the app container on reinstall. Evidence gathered across two
> `flutter test` runs measures the installer, not the app.

### The measurement done properly

`tool/language_restart_proof.sh` + `integration_test/language_restart_persistence_test.dart`
install **once** and only launch thereafter, with the phase passed in a file
inside the app's own Documents directory (a `--dart-define` is fixed at compile
time and both phases must run the same binary). The container path is compared
before and after; a changed container voids the run.

English, written through `SaveLanguageUseCase` — the app's only write path for
this value — then the process killed and relaunched:

```
[LANG-PROOF] phase=write  wrote=en readback=en
=== TERMINATE (process killed; install untouched) ===
[LANG-PROOF] phase=verify persisted=en resolved=en
SAME container — this was a process restart, NOT a reinstall.
```

**The language survives a process restart.** Persisted and resolved both come
back `en`. The finding is closed as a harness artifact, and the harness that
would have caught it now exists.

---

## 2. The app-lock prompt — I retracted a real finding, then un-retracted it,
   and the truth is narrower than either

The sequence, stated plainly because two of the three steps were wrong:

1. **Reported** as a mismatch from a host screenshot showing an Arabic prompt.
   That screenshot was taken against an empty container, so the app was in its
   default language and the screenshot proved nothing. The report was
   unfounded.
2. **Retracted** on the strength of an in-process test that background/resumed
   the app and saw the correct language in both directions. That test could not
   see the defect: by the time it triggered the lock, the app had long since
   resolved its language. The retraction was also unfounded.
3. **Reproduced for real** on the same-install restart harness above. On a
   genuine cold start with English persisted:

   ```
   persisted=en resolved=en promptSeen=true promptAr=true promptEn=false
   ```

   The gate raises the prompt from a post-frame callback on the first frame,
   before `userSettingsProvider` has read the language out of the database, so
   `context.l10n` still holds the app default. iOS is handed that string once
   and draws it.

### Why it is not a V1 defect

It requires the persisted language to differ from the app default. In V1 it
never can — see §3. Every V1 user has `language = 'ar'`, which is also the
default, so the prompt the gate composes early is the right one.

### A fix was written and reverted

Caching the language beside the lock flag in the keychain, so the gate could
read it without waiting on the database. It verified once:

```
promptAr=false promptEn=true        (after the fix, English)
```

and then **failed on the next run**, because the cache is written by a provider
that had not necessarily run before the process ended:

```
promptAr=true  promptEn=false       (same fix, English, next run)
```

A change to the gate between a stranger and the user's financial history, which
works in one run and not the next, does not ship. It is reverted. The
deterministic place for such a cache is the moment the language is written —
which is dead code today, for the reason in §3.

---

## 3. The fact underneath both — V1 has no language switcher

`user_settings.language` is created as `'ar'`:

```sql
INSERT INTO user_settings(id, country, currency, language, ...)
VALUES (?, 'SA', 'SAR', 'ar', ...)
```

and the only code in `lib/` that ever writes it is `SaveLanguageUseCase`:

```
grep -rn "saveLanguageUseCaseProvider" lib/ | grep -v app_providers   → nothing
grep -rn "SaveLanguageUseCase"        lib/ | grep -v usecases|providers → nothing
```

**Zero callers.** There is no language control in Settings, no ARB copy for one,
no onboarding step that sets it, no migration, and nothing that seeds it from
the device locale — `localeProvider` reads the settings row and nothing else.

So in V1 as it stands, every user runs in Arabic, permanently, and the English
localization is unreachable from inside the app.

That may be exactly right: this is an Arabic-first product for the Saudi market,
and the English work may be groundwork for a later release. But it changes what
the bilingual evidence in this programme means, and the owner should decide
knowingly rather than by omission:

* The English half of every bilingual walk, matrix and capture in
  `V1_LOCALIZATION_MATRIX_2026-09-17.md` and
  `V1_UI_VISUAL_CLOSURE_2026-09-18.md` describes a state a user cannot reach.
  Those documents set the language by writing `settings.language` directly —
  `V1_LOCALIZATION_MATRIX_2026-09-17.md:23` says so — which is the same
  non-shipping path used here.
* The seven UI defects fixed during the closure pass were all real, and five of
  them were English-only. If English never ships, five of those fixes protect a
  future release rather than this one. The other two — the country selector's
  1.00:1 contrast and the welcome story's illustration over its own copy —
  affected Arabic as well.

**No change made.** Adding a language switcher is product scope and a
reviewer-visible feature at release closure, which is the thing the
`BackupScreen` decision already ruled out for V1. This is recorded for the
owner's call.

---

## 4. What was added

| | |
|---|---|
| `integration_test/language_restart_persistence_test.dart` | two-phase, same-install language persistence, both directions, and the unlock prompt alongside it |
| `tool/language_restart_proof.sh` | installs once, launches twice per language, terminates in between, and voids the run if the container changes |

Neither is in the unit suite: both need a device and a real process restart.

---

## 5. Status — as of the investigation

| | |
|---|---|
| Persistence finding | **CLOSED** — harness artifact, proven |
| App-lock prompt on cold start | Real, **not reachable in V1**, fix reverted as unreliable |
| No language switcher in V1 | **OPEN — owner decision**, no change made |

---

## 6. Closed, 2026-09-18 — the switcher shipped and the prompt was fixed

### 6.1 Settings → Language

`_showSettingsPicker` offering **العربية** and **English** as endonyms, next to
Country and Currency, going through `SaveLanguageUseCase` — the app's real write
path, still the only one. Arabic remains the default for new users; the settings
row is still created `'ar'` and no default-language policy changed.

Endonyms rather than ARB strings on purpose: a reader looking for their own
language looks for its own name, and translating the list labels the language
you cannot read in the language you cannot read.

### 6.2 The prompt fix, and why this cache is not the last one

`core/security/lock_prompt_language.dart` — a keychain mirror of
`user_settings.language`, written by **every path that writes the column**, in
the same await chain as the write:

| Writer | Why it writes |
|---|---|
| `SaveLanguageUseCase` | Settings → Language; the only path a user can take |
| `PlanningPullService` | a server row carrying a language — how a second device inherits the first's choice |
| `RestoreBackupUseCase` | a backup snapshot carrying a language, mirrored **post-commit** so a rolled-back restore leaves the mirror alone |

The gate reads it instead of `context.l10n`: one local keychain read, no
database, no provider, no network, no bootstrap, taken while the lock screen is
already up. **The lock still fires on the first protected frame, and nothing
about authentication changed.**

The earlier attempt cached the same value from a Riverpod provider and was
reverted after passing once and failing the next run. The difference is not the
storage, it is the **write site**: "when a provider runs" cannot be ordered
against the process ending, and "the line after the database write" can.

`test/core/security/lock_prompt_language_test.dart` fails if a fourth writer of
the column appears without a mirror, so the coverage this argument depends on is
enforced rather than asserted.

### 6.3 What it does NOT cover, stated

iOS keychain items outlive the app container. After a **reinstall** the mirror
survives while the database returns to its default, so a user who had chosen
English and reinstalled sees one English prompt over an Arabic app until they
choose again. Closing it means seeding the mirror where the settings row is
created — inside `AppDatabase`, which every unit test opens without a keychain.
One wrong-language prompt in a rare path, in the language the user last asked
for, was not worth putting a platform channel in the data layer's constructor
path. Recorded, not traded away quietly.

### 6.4 Device evidence — one install, eight launches, both directions

`tool/language_restart_proof.sh` installs once and only launches thereafter. The
language is chosen by **tapping the real Settings screen** — the shell's own
settings icon, the Language tile, the language — never written behind the UI's
back, and no `--dart-define` forces it.

```
=== LANGUAGE: en ===
[settings] chose=en persisted=en resolved=en mirrored=en   lock armed=true
=== TERMINATE (process killed; install untouched) ===
[verify]   persisted=en resolved=en mirrored=en promptSeen=true promptAr=false promptEn=true
=== TERMINATE ===
[ui]       persisted=en resolved=en direction=ltr wantedCopyVisible=true otherCopyVisible=false

=== LANGUAGE: ar ===
[settings] chose=ar persisted=ar resolved=ar mirrored=ar   lock armed=true
=== TERMINATE ===
[verify]   persisted=ar resolved=ar mirrored=ar promptSeen=true promptAr=true  promptEn=false
=== TERMINATE ===
[ui]       persisted=ar resolved=ar direction=rtl wantedCopyVisible=true otherCopyVisible=false

before: …/Application/FC120938-8349-4BA9-B091-66A4720BC623
after : …/Application/FC120938-8349-4BA9-B091-66A4720BC623
SAME container — this was a process restart, NOT a reinstall.
```

`promptAr=false promptEn=true` under `persisted=en` is the line the whole
exercise is for: on the pre-fix gate the same cold start produced
`promptAr=true promptEn=false`.

### 6.5 The prompt, photographed

The `native` phase launches with **nothing intercepting the platform call**, so
iOS draws its own sheet and the host photographs it. This is the string as a
user sees it, not as the channel carries it — and it is the capture that every
earlier attempt at this surface failed to get:

| | |
|---|---|
| `~/.qirsh-qa/language-restart-proof/applock-native-prompt-en.png` | **"Unlock Qirsh to protect your financial data."** under the system's own "Enter iPhone Passcode" header |
| `~/.qirsh-qa/language-restart-proof/applock-native-prompt-ar.png` | «افتح قِرش لحماية بياناتك المالية.» |

The phase is photographed and killed rather than waited on: a native sheet stops
frame production, so the run hangs behind it by design.

The language picker itself is captured by the `ui` phase, which leaves it open
over the settings list: `language-en.png` (LTR, «English» selected) and
`language-ar.png` (mirrored RTL, «العربية» selected), each over a settings
screen rendering entirely in its own language.

### 6.6 Unit evidence

| Check | File |
|---|---|
| The control exists, offers both languages, uses the real write path, and what it writes is what `localeProvider` reads | `test/features/settings/language_selector_test.dart` |
| The prompt follows the mirror and not the ambient locale — **fails against the pre-fix gate** | `test/core/security/app_lock_prompt_language_test.dart` |
| The mirror round-trips, degrades safely, and every writer of the column mirrors it | `test/core/security/lock_prompt_language_test.dart` |

### 6.7 Amended status

| | |
|---|---|
| Persistence finding | **CLOSED** — harness artifact, proven |
| App-lock prompt on cold start | **FIXED** — both languages verified on device and in unit tests |
| Language reachability | **CLOSED** — Settings → Language ships; Arabic still the default |
| Reinstall carrying a stale mirror | **OPEN, recorded** — §6.3 |
| Arabic-only campaign notifications | **OPEN, recorded** — `notification_journey_service.dart`; needs the `notificationLanguage` pattern, not a context |
