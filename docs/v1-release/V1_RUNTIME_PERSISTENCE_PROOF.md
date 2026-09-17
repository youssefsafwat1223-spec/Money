# Persistence, import and cloud backup — the runtime proofs

Audit items 26, 27, 29 and 30. All four were **NOT DONE**. All four are now
closed with runtime evidence, and each one has a stated boundary.

---

## Items 26–27 — process restart and device reboot

### Why the obvious test was wrong

The natural way to write this is two `flutter test` runs: write in the first,
verify in the second. That was tried earlier in this programme and reported
**both Drift layers LOST, Keychain SURVIVED**.

Nothing had been lost. `flutter test -d <device>` **reinstalls the app on
every invocation**, iOS **replaces the app container on reinstall**, and the
Keychain lives *outside* the container. The test was measuring the installer.

Any evidence that assumes data carries between `flutter test` invocations is
measuring the installer, not the app. That is the trap this proof is shaped
around.

### The shape of the real proof

`app/tool/process_restart_proof.sh`:

1. Build the probe as its **own app bundle**
   (`flutter build ios --simulator -t integration_test/…`).
2. `simctl install` — **once**. Nothing after this line reinstalls.
3. `simctl launch` (phase `write`) — writes a marker transaction through the
   shipping repository, then reads it back through a **cold second
   connection** (`AppDatabase.openSecondary`), which re-derives the SQLCipher
   key from the Keychain and opens the file fresh. A row visible there
   genuinely reached disk.
4. `simctl terminate` — the process is killed.
5. `simctl launch` (phase `verify`) — looks for the marker.
6. `simctl shutdown` + `simctl boot` — the device reboots.
7. `simctl launch` (phase `verify`) — looks for the marker again.

The phase cannot be a `--dart-define` (fixed at compile time; both phases must
run the *same* binary). `SIMCTL_CHILD_*` environment injection was tried and
did not reach the Dart isolate, so the harness writes the phase into a file in
the app's own Documents directory — observable from both sides, and its
absence is an explicit default rather than a silent one.

### Result

```
write               db_exists=true  wrote=qa-restart-marker-0001  on_disk=true
terminate + launch  found=true  merchant=QA_RESTART_PROOF  shell_mounted=true
shutdown + boot     found=true  merchant=QA_RESTART_PROOF  shell_mounted=true

container before  .../Application/AB921F49-36F9-46DC-BC77-34ED27C8584E
container after   .../Application/AB921F49-36F9-46DC-BC77-34ED27C8584E
database inode    15006659  →  15006659  →  15006659
```

**The container UUID and the inode are the point.** They are what distinguishes
a process restart from a reinstall — exactly the confound that made the
earlier attempt report data loss that had not happened. The script fails with
"the proof is void" if the container changes.

`shell_mounted=true` in every phase means the app did not merely reopen its
database, it reached a usable screen.

### Stated boundary

The script judges on the probe's own `[RESTART-PROOF]` lines, not on
`flutter_test`'s exit summary, and prints a note saying so. The reason: the iOS
accessibility client attaches to a launched app and holds a `SemanticsHandle`
for the life of the process, which `flutter_test`'s teardown reports as a leak
**after** every assertion here has already run. It is reported in the output,
not hidden — and if a real assertion fails, `DONE` never prints and the check
fails with it.

This is a **simulator**. A physical-device reboot (with Secure Enclave-backed
Keychain items and real Data Protection classes) is not the same system, and
is not claimed.

---

## Item 29 — applying an import

`app/integration_test/import_apply_test.dart`.

The previous boundary was honest but left the most important claim about
import unproven: *does applying it put the right rows in the database*.

Closed without collateral damage:

* three rows the harness invents, each with a merchant name
  (`QA_IMPORT_APPLY_…`) that exists nowhere else in the corpus, so every
  assertion addresses exactly the rows it created;
* `ImportMode.merge` only ever adds — `replace` is refused for external CSV by
  the service itself and is not attempted;
* teardown deletes exactly those rows and asserts the total count returns to
  its baseline.

```
baseline transactions=0
format=genericCsv rows=3 errors=false
applied imported=3 duplicates=0 skipped=0 failed=0
total 0 -> 3; marker rows=3
all three rows verified exactly
ledger restored to 0
```

"Verified exactly" means per row: **amount as exact minor units** (1237,
49905, 799 — not a double that survived by luck), **currency as written in the
file** (a substituted default would show, and one row is deliberately USD
against a SAR account), and **the calendar date the user sees**.

That last one found a real subtlety. The importer reads a CSV date as *local
midnight* and stores UTC, so `2026-03-04` is on disk as `2026-03-03T22:00:00Z`
at UTC+2. That is correct — rendered back in the device's timezone it is the
day the file said — and the first version of the assertion, which compared the
stored prefix, was wrong and would have failed in any timezone east of UTC.
The assertion now compares the calendar date in local time, which is what the
user actually reads.

### Stated boundary

Merge only. Replace-mode restore is `destructive_phase_test`, which owns its
own teardown.

---

## Item 30 — cloud backup, end to end

`app/integration_test/cloud_backup_e2e_test.dart`.

The two previous objections were "it needs a passphrase this harness has no
business inventing" and "it writes to the owner's storage". Both are
answerable rather than fatal:

* the passphrase is generated from `Random.secure` **in the test**, used once,
  never logged, and never written anywhere but process memory. Inventing a
  passphrase is only wrong if it becomes a real user's passphrase;
* the upload lands under the QA user's own RLS-scoped path, and teardown
  deletes it.

```
enabled — recovery code issued (14 chars, not logged)
status enabled=true lastBackupAt=true
remote backup present
wrong passphrase rejected with BackupError.decryptFailed
restore plan built — operationId present, warnings=0, tables=18, rows=721
teardown complete — remote backup removed, backup disabled
```

Reaching a plan means the payload **downloaded, decrypted and parsed**: 18
tables, 721 rows. And the negative that matters is asserted — a wrong
passphrase must fail. An "encrypted" backup that opens without the key is the
defect this test would otherwise be blind to.

### What it found

This test is the first thing that ever ran the cloud path end to end, and it
found two defects immediately. Both are fixed; see the commit
`fix(backup): cloud backup was invisible, and enable bypassed cloud consent`.

1. **`hasRemoteBackup()` could not see a backup the app had just written.** It
   looked only for the legacy fixed object `<owner>/backup.enc`; `backupNow()`
   writes `<owner>/g/<generationId>.enc` and commits a pointer. That check is
   what the Data Transfer screen and the post-reinstall restore prompt ask
   before offering to restore — so a user who reinstalled was told they had no
   cloud backup while their backup existed and `prepareRestore` would have
   opened it.

2. **Turning backup on bypassed the cloud-consent gate.** The screen called
   `backupServiceProvider.enable()` directly; the gate lives in
   `RemoteBackupController`. An encrypted copy of the entire ledger was
   uploaded with cloud consent OFF.

### Stated boundary

`commitRestore` is **deliberately not called**. Commit replaces the local
database, and the confirmation capability exists precisely so that cannot
happen without an explicit human decision. So the cryptographic round trip is
proven; "a restore actually repopulates the ledger" is covered by
`destructive_phase_test`, not here.
