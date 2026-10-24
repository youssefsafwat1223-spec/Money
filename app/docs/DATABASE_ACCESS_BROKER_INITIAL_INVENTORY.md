# Amendment O initial broker participant inventory

Initial bounded source unit, 2026-10-14. No integrated host/runtime proof is
claimed. Authority: approved-native-offline-amendments/astra-review.md Amendment O
and its human-approval.json (answer: «أوافق على N وO بهذا النطاق والحدود»).

## Status correction (Astra R45 R4)

The "unwired" statements below describe the initial O-H1 unit and are SUPERSEDED.
Since O-H1..O-BX/O-RW the primary, cold-launch, in-memory signed-out and offline
local-read opens reserve with the coordinator (`AccountScopeHost`, `AppSession`),
the local-read restoration owns an atomic exclusion with exact-generation close
acknowledgements, and bootstrap fails closed when the coordinator cannot be
created or proven. Still NOT wired: `transition(maintenance)` has no production
caller, and engine-recreation / second-OS-process behaviour is unproven source
evidence only.

## Contract B and coordinator ownership

The existing PROCESS_ACCESS_INVENTORY.md single-OS-process database-opening
contract remains consistent with inspected source: Android declares no
android:process; iOS ShareBankMessage and BankMessageShortcuts contain no Flutter
engine or native SQLite open. The notification plugin's separate Flutter engine
is a same-process participant, not evidence of a second OS process. The capture
processor's former background opener is retained but documented unreachable;
it must remain denied if called without a live issuer.

Installed SDK package configuration records Flutter 3.47.3; installed
bin/internal/engine.version records 06a2e2a110089dff50fe635cffd2a61e1b24fbcd.
Installed dart:ui IsolateNameServer documentation says isolates share a global
name-to-port map. Official engine source at that revision, runtime/dart_vm.cc,
passes a shared IsolateNameServer to DartVM and retains it in the VM. Therefore
this inspection does not assert that the map is engine-local. A candidate
registration must never remove its mapping or replace an unresponsive/dead port;
missing discovery must deny entrants, never authorize a background coordinator.
This is source evidence, not executed multi-engine/process-lifetime proof.

Pinned source:
https://raw.githubusercontent.com/flutter/flutter/06a2e2a110089dff50fe635cffd2a61e1b24fbcd/engine/src/flutter/runtime/dart_vm.cc

## Required participants, all currently unwired

* AppDatabase.open/openSecondary/openReadOnlyExisting and its internal Drift
  background connection: reserve before open; transfer uncertain handles before
  settling reservations; acknowledge only actual close.
* AppDatabase.runExclusiveMaintenance/runFileExclusiveMaintenance: deny new
  reservations, drain pending opens and holders, then independently authorize.
* ReplicaStore.openReplica/openStaging/read-only restore, staging discard/swap,
  remove/recoverPendingRemovals and legacy adoption: participate in the same
  coordinator rather than separate store-local maps.
* AppSession, AccountScope, bootstrap_runner, RemoveDataFlow and
  RebootstrapService: bind exact current authenticated host lifecycle or verified
  existing read scope; revoke before drain and await confirmed closure.
* CapturedMessageProcessor ownerless secondary path: defer without host issuer.
* LocalNotificationService._runBackgroundAction: authorize before
  PendingNotificationActions.record; current source stages first and remains
  uncorrected in this initial inspection.
* core/backup/restore_service.dart is an additional existing maintenance caller
  outside O's enumerated edit list. It calls both maintenance methods. (O-BX-1:
  it now runs inside `AppSession.runMaintenanceParticipant`, the restoration's
  admission drain awaits or refuses it, and `AppDatabase.close` awaits a running
  maintenance and refuses queued or still-draining ones. No other production
  caller of the maintenance methods exists; Remove data's replica removal is the
  only other intent creator.)

Existing DatabaseLeaseManager and DatabaseProcessLiveness writes remain separate
authenticated lifecycle work. Their fcntl lock does not exclude same-process
isolates. Local-read discovery must not invoke those sidecar-creating methods.

## Initial bounded API and retained limitations

The initial unit adds DatabaseHostAdmission in AppSession with a private
constructor and exact retained object identity. AppSession captures its actual
AccountScopeHost.current object, DB, scope generation, private admission epoch
and auth-loss sequence, current bound SDK session, completed onboarding and
committed admitted UID. Receipt validation checks these again, including actual
fresh matching SDK and a writable usable DB. Public AdmissionAuthority constructors
and LocalReadIssueProof callbacks are not accepted as broker authority. Repeat capture reuses the exact still-current receipt. A failed current check
stickily revokes that object; the same scope/epoch/loss/SDK lifetime cannot
remint it. Rebinding the SDK client retires it immediately.
No storage, SDK request or scope publication is performed by receipt capture.

The broker registers a random-identity coordinator once in IsolateNameServer and
never removes the named mapping. Collision, missing discovery, unresponsive
endpoint or uncertain cleanup cannot start a replacement. Client communication
via SendPort does not itself grant access. Host issuance before job launch creates
a transferable opaque Dart Capability recorded against the exact retained
AppSession issuer, process nonce and broker generation. One job permits one
reserved opener. Both reservation and publication verify that exact permit;
discovery/public client construction and arbitrary Capability tokens confer no
authority. Old clients never adopt a later owner or same-UID readmission. Closed
jobs discard permits; unknown opens/failed closes remain tracked. Transitions
retire all prior jobs before draining. Mode transitions restrict
synchronously, drain pending opens and actual holders, and keep quiescing on a
failure/timeout. Opening losers are retained while client actual-close callbacks
run; failure never releases their registration. Unknown failed opens deliberately
retain their reservation because an exception is not proof no handle exists.

No authentic local-read host scope currently exists. localRead transition is
explicitly unavailable; neither the helper grant capability nor read metadata can
mint a writable receipt. Maintenance requires independently supplied current
host receipt after drain; host startup opening before publication remains
unwired because it needs a separate bounded in-flight admission reservation.
The existing published host DB is not retroactively covered by this initial
broker. All real open/maintenance/staging entrances listed above remain unwired.
This unit must not be presented as enforcing production DB exclusion yet.

Tests use F2Fixture's actual published scope and MockSupabase's SDK session for
the normal writable issuer. Two independently spawned same-process Dart isolates
use SendPorts to exercise pending-open versus transition and active-holder versus
transition, with actual client open/close callbacks and attempt assertions.
Separate protocol-only stale token tests do not claim actual multi-engine proof.
No SDK execution was attempted by the implementer; root host execution and Astra
final frozen-source review remain required. Unsupported/dead coordinator tests
use distinct closed/unresponsive ReceivePorts, not a claim that the actual
registered process coordinator was killed and recovered.
