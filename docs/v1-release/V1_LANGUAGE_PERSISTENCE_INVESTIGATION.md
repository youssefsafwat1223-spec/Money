# Language Persistence — investigation and resolution, 2026-09-18

Investigating the finding raised at the end of the UI closure pass: *"a language
written in one process reads back as Arabic in the next."*

Three things came out of it. The first closes the finding. The second corrects a
retraction I made. The third is the fact both of them were standing on, and it
is the one that needs an owner decision.

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

## 5. Status

| | |
|---|---|
| Persistence finding | **CLOSED** — harness artifact, proven |
| App-lock prompt on cold start | Real, **not reachable in V1**, fix reverted as unreliable |
| No language switcher in V1 | **OPEN — owner decision**, no change made |
