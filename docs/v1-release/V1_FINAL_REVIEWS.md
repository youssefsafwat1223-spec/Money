# V1 final reviews — items 98–99

Two independent reviewers were run with separate briefs. Neither was told
anything about the other's findings, per instruction. This records what each
found, what was done about it, and — equally — what was **not** run.

## What was not run, and why

**Codex red-team: NOT RUN.** There is no `codex` binary on this machine:
`which codex` fails, and nothing matching appears under `/opt/homebrew/bin`,
the npm global prefix, `/usr/local/bin` or `~/.local/bin`. A `~/.codex/`
configuration directory exists without the tool it belongs to.

Recorded as **REVIEW_DEFERRED**. Not a pass, and not counted as one. This is
the only engineering-resolvable item left open in the final audit, and it is a
tool-availability problem rather than a code one.

**Reliability note.** Four earlier review attempts died — two on
`ECONNRESET`, two on a stalled stream — during a window when network calls
from this machine were failing generally (the Android integration run failed
at the same time with `Connection refused` reaching Supabase). The two reviews
below are the runs that completed.

---

## Review A — security and privacy

Scope: the backup service, the backup controller, the app-lock service, and the
Android notification channels.

### Findings, and what was done

| # | Severity | Finding | Action |
|---|---|---|---|
| A1 | P2 | `deleteRemoteBackups()` deletes the generation object *before* clearing the pointer. If the delete lands server-side but then throws, the pointer names a missing object — and `hasRemoteBackup()` trusts the pointer, so a restore is offered that always fails. | **Fixed by A3's change** — restore now falls through to the legacy object, so a dangling pointer is no longer terminal. The ordering itself is unchanged; reversing it would risk orphaning an object instead, which is the worse failure. |
| A2 | P2 | `hasRemoteBackup()` reports a backup when EITHER the pointer or the legacy object exists; `prepareRestore()` accepted only the pointer once one existed. Discovery and restore disagreed on what "restorable" means. | **Fixed.** A failed generation download falls back to the legacy object. |
| A3 | P2 | `hasRemoteBackup()` swallows a pointer-read failure and falls through; `prepareRestore()` does not catch it at all. | **Fixed by the same change** — the generation branch is now inside a `try`. |
| A4 | — | `deleteRemoteBackups()` does not clear local backup state, so `status().enabled` stays true and a later `backupNow()` makes a new backup. | **Not changed — this is the documented design.** `disable()` and `deleteRemoteBackups()` are deliberately independent switches ("DISABLE stops future uploads ONLY… deleting remote data is a SEPARATE, explicit destructive action"). Deleting the current backup while backup is still on producing a new one is the stated contract, not a defect. Recorded rather than silently changed. |
| A5 | P2 | `_run()`'s busy path returns `null` without touching `state`, and `null` is also how `enable` signals "consent missing" — a caller cannot tell them apart. | **Not changed.** Real, and unreachable: see the reachability note below. Recorded. |
| A6 | P2 | `onSignedOut()` clears `_busy` while an operation is running; the still-running operation can then write `enabledIdle` *after* sign-out set `disabled`, so the previous user's "Protected" badge reappears on a signed-out screen. | **Not changed.** Real, and the most interesting of the unreachable set — it needs an epoch guard, not a one-line fix. Recorded for the owner. |
| A7 | P2 | `refresh()` causes network egress with no consent check. | **Fixed in its reachable form**, which is worse than the one reported — see below. |
| A8 | — | No secret (passphrase, recovery code, content key) can reach a log line or exception message. | HOLDS. |
| A9 | — | All ten `AndroidNotificationDetails` sites go through `_channel()`. | HOLDS. |
| A10 | NIT | `showTestNotification` passes a different `channelDescription` than `showLightCaptureNotification` for the same channel id; Android keeps whichever was created first. | Recorded. Cosmetic — same id, same importance. |

### A7, in its reachable form

The reviewer found `refresh()`. `refresh()` is only reached through
`remoteBackupControllerProvider`, which only `backup_screen.dart` watches —
and that screen is unreachable in V1 (see the reachability note). So the
version they found could not fire.

The same defect on a **live** path was worse: `_checkLegacyBackup()` runs in
`initState` of the Data Transfer screen, gated on `SupabaseConfig.isConfigured`
alone. That asks whether the app *can* reach the server, not whether the user
agreed that it should. Opening Data Transfer read the generation pointer and
listed the user's storage prefix — two authenticated requests — with cloud
consent off.

And the second of those two requests exists only because `hasRemoteBackup()`
was widened earlier the same day. **Fixing one defect increased ungated egress
elsewhere**, which is exactly what an independent review is for.

Now gated on `EgressClass.backup`. With consent off there is nothing to offer
anyway — a cloud restore cannot run — so the tile stays hidden and no request
is made. The test asserts the consent check *precedes* the request.

### Reachability note

A5, A6 and the reported form of A7 all live behind `BackupScreen`, which has
no reference anywhere in `lib/` outside its own file. `/backup` is a permanent
redirect to `/data-transfer`, and cloud backup is retired in V1. They are real
code defects in code no V1 user can reach, and they are recorded rather than
fixed because changing unreachable code carries risk without benefit — and
because the owner should decide whether that screen returns at all.

---

## Review B — red team, the localization claim

Scope: attack "zero untranslated user-facing strings remain".

### The finding that mattered

**An Arabic comma in English copy.** `coupon_widgets.dart` joined country codes
with «،» unconditionally, so an English reader on a multi-country offer saw
**"Available in SA، AE"**.

The way it survived is the more important half. The extractor marked it
"already bilingual" because its `code:` marker matched
`CouponCodePill(code: offer.code!)` fourteen lines below. `code:` is also an
ordinary Dart named argument, and a substring test cannot tell one from a
`DataPortabilityError`.

The reviewer's own words are worth keeping: *"zero" is "zero that this grep can
see."* That is fair, and it is the right standard to hold the claim to.

Both halves fixed:

* the separator follows the reader, using the pattern already present in
  `app_transaction_row.dart` for the same glyph;
* the markers are anchored to the actual enums (`code: BackupError.`,
  `code: ImportIssueCode.`, …), so a parameter that merely happens to be called
  `code` cannot rescue anything. Re-running with the stricter markers reported
  the coupon comma immediately — the check working.

### The structural finding

`generic_transaction_import.dart` is excluded at file level because most of its
Arabic is CSV keywords and digit tables. It also raises three user-facing
`ImportIssue`s — and a fourth added without a `code:` would print Arabic in the
English build and never be reported. That is precisely what the tool's own
comment says file-level exclusions must not leave.

Closed with `import_issue_coverage_test`, which asserts every `ImportIssue(` in
`lib/` carries a code. Verified by deleting one: the test names the file and
the line.

### Exclusions that held, and two that were dropped

| Exclusion | Verdict |
|---|---|
| `budget_alert_planner.dart`, `capture_review_notification.dart` | HOLD — audited literal by literal; every Arabic string is the Arabic arm of an `en ? … : …` or of `_arDays`, whose `_enDays` counterpart sits beside it |
| `design_gallery_screen.dart` | HOLD — the `/design` route is inside `if (kDebugMode)` and is the class's only construction site |
| `foundation_home_screen.dart` | HOLD, and stronger than claimed — zero references anywhere in `lib/`. Dead code, not merely debug-only |
| `generic_transaction_import.dart` (the digit tables and CSV keywords) | HOLD |
| `conflict_policy.dart` | **DROPPED** — its Arabic is gone; only the explanatory comment remains. A vacuous exclusion protects nothing and widens the blind spot |
| `report_pdf_renderer.dart` | **DROPPED** — the stated reason ("deliberately Arabic in every language") was wrong about the code, which is `rtl ? 'قرش' : 'Qirsh'`. The per-literal marker covers it |

The reviewer also flagged that these lines render bidi-reordered in a terminal
and that a comment can be mistaken for live code — which is worth repeating to
anyone re-running this audit.

---

## The method that produced the most findings

Three of the defects fixed today came from turning the same adversarial
question on the audit's own weakest claim: *is everything excluded as "data,
not copy" really data?*

* `كل المصروفات` — the all-expenses pseudo-category, fixed id, unrenameable,
  read Arabic in the English build on every whole-ledger budget;
* the Smart Inbox title for an unparseable message;
* `'ميزانية ' || amount` composed in SQL, putting an Arabic word on the
  planning-conflicts sheet in every language.

A category label on an exclusion list is an assertion, and it deserves the same
scrutiny as a line of code.
