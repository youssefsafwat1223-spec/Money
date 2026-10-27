import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';

import '../../core/session/f2_fixture.dart';
import '../../harness/paused_egress_support.dart';

// Separately tracked ordinary-disable investigation. The public UI consent
// core starts while its real capability/provider are live. Only the gate's
// pre-allocation scheduling point and platform dependencies are controlled.
class _DisableHold {
  final reached = Completer<void>();
  final release = Completer<void>();
}

class _PauseDisableGate extends CloudEgressGate {
  _PauseDisableGate(CloudEgressStore superStore)
      : super(store: superStore, activeOwner: () async => kRigOwner,
            resolved: true,
            nativeInflight: (_) async => (count: 0, latestDeadline: null));
  final holds = <_DisableHold>[];
  final firstReached = Completer<void>();

  @override
  Future<DisableFreeze> beginDisabling({required String owner,
      required int reservedVersion, bool Function()? isCurrent}) async {
    final hold = _DisableHold();
    holds.add(hold);
    if (holds.length == 1) firstReached.complete();
    hold.reached.complete();
    await hold.release.future;
    return super.beginDisabling(owner: owner, reservedVersion: reservedVersion,
        isCurrent: isCurrent);
  }
}

class _Settings extends DriftUserSettingsRepository {
  _Settings(super.db);
  int saved = 0;
  @override
  void afterConsentChoice(ConsentCapability capability, ConsentChoices choices) {
    saved++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ordinary disable after real same-UID readmission stays restrictive '
      'without stale settings save or false OFF completion', () async {
    final rig = EgressRig();
    final gate = _PauseDisableGate(rig.gate.store);
    final previousGate = CloudEgressGate.instance;
    CloudEgressGate.instance = gate;
    ConsentAuthority.egressFrozen = false;
    Future<T> phase<T>(String label, Future<T> operation) async {
      printOnFailure('START $label');
      final value = await operation.timeout(const Duration(seconds: 4),
          onTimeout: () => throw StateError('milestone timed out: $label'));
      printOnFailure('DONE $label');
      return value;
    }
    Future<void> reached(String label, Future<void> barrier,
            Future<Object?> operation) => phase(label, Future.any<void>([
          barrier,
          operation.then<void>((outcome) => throw StateError(
              '$label: operation settled before barrier: $outcome')),
        ]));
    final f = await phase('fixture creation', F2Fixture.create());
    ProviderContainer? outgoing;
    Future<Object?>? oldOutcome;
    try {
      final sdk = await F2Fixture.liveClient(kRigOwner);
      f.session.configureConsentSdkClient(() => sdk);
      await phase('initial same-UID admission', f.signIn(kRigOwner));

      ProviderContainer container(AppDatabase database, _Settings settings) =>
          ProviderContainer(overrides: [
            captureDeviceRegistrationServiceProvider.overrideWith((ref) {
              final service = CaptureDeviceRegistrationService(
                settingsRepository: settings,
                gate: gate,
                isIos: () => false,
                isAndroid: () => false,
                isBackendConfigured: () => false,
                readSession: () => f.host.activeUid == null ? null :
                    (uid: f.host.activeUid!, jwt: 'jwt'),
                readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
                captureWorkAuthority: f.session.captureLocalWorkAuthority,
                isCurrentScope: () =>
                    identical(f.host.current?.database, database),
              );
              ref.onDispose(service.dispose);
              return service;
            }),
          ]);
      ConsentLocalWork work(ConsentCapability capability) => ConsentLocalWork(
          capability, <T>(action) =>
              f.session.runConsentLocalOperation(capability, action));
      Future<Object?> decline(CaptureDeviceRegistrationService service,
              _Settings settings, ConsentCapability capability) =>
          applyConsentChoice(scope: work(capability), repository: settings,
              writer: settings, service: service, declined: true)
              .then<Object?>((_) => null, onError: (Object error) => error);

      final oldDb = f.host.current!.database;
      final oldSettings = _Settings(oldDb);
      outgoing = container(oldDb, oldSettings);
      final oldService = outgoing.read(captureDeviceRegistrationServiceProvider);
      final oldCapability = f.session.captureConsentCapability()!;
      await phase('initial typed enable', oldService.enableCloud(
          write: ConsentWrite(oldCapability,
              const ConsentChoices(cloud: ConsentState.accepted))));
      final oldSaved = oldSettings.saved;
      oldOutcome = decline(oldService, oldSettings, oldCapability);
      await reached('outgoing pre-allocation', gate.firstReached.future,
          oldOutcome);
      expect(oldCapability.isCurrent, isTrue,
          reason: 'the UI-core call entered before lifecycle retirement');
      expect(ConsentAuthority.egressFrozen, isTrue);

      // This is actual AppSession same-UID admission, not a synthetic stale
      // Boolean. Ordinary disable is outside the local drain, so it can finish.
      await phase('real same-UID readmission', f.signIn(kRigOwner));
      expect(oldCapability.isCurrent, isFalse);
      outgoing.dispose();
      outgoing = null;
      final newDb = f.host.current!.database;
      final fresh = f.session.captureConsentCapability()!;
      expect(fresh.isCurrent, isTrue);
      expect(fresh.epoch, isNot(oldCapability.epoch));
      final newSettings = _Settings(newDb);
      final before = await phase('readmitted settings before old release',
          newSettings.getSettings());
      expect(before.cloudProcessingEnabled, isTrue);
      final prior = (await gate.store.readOwnerLayers(kRigOwner)).records;
      expect(prior, isNotEmpty);
      expect(prior.every((record) => record.state == EgressState.on), isTrue);
      final generationBefore = prior.first.transitionGeneration;
      expect(prior.every((record) =>
          record.transitionGeneration == generationBefore), isTrue);

      // Static in-flight serialization prevents a new Cloud enable or another
      // independent disable while this old flight is paused. Readmission issued
      // fresh local authority but did not establish a successor Cloud grant or
      // a successor-owned freeze. Conservative old restriction is permitted.
      gate.holds.first.release.complete();
      final oldError = await phase('outgoing completion after release', oldOutcome);
      expect(oldError, isA<StaleAdmissionException>(),
          reason: 'the retired typed callback must refuse instead of reporting OFF');
      expect(oldSettings.saved, oldSaved,
          reason: 'no stale typed save completed');
      expect(newSettings.saved, 0);
      final after = await phase('readmitted settings after old completion',
          newSettings.getSettings());
      expect(after.cloudConsentState, before.cloudConsentState);
      expect(after.aiConsentState, before.aiConsentState);
      expect(after.consentVersion, before.consentVersion);
      final records = (await gate.store.readOwnerLayers(kRigOwner)).records;
      expect(records, hasLength(3));
      expect(records.every((record) =>
          record.state == EgressState.disabling &&
          record.transitionGeneration == generationBefore + 1), isTrue,
          reason: 'failed local OFF keeps the conservative incomplete marker');
      expect(records.where((record) => record.state == EgressState.off), isEmpty,
          reason: 'no successful OFF completion is fabricated');
      expect(ConsentAuthority.egressFrozen, isTrue,
          reason: 'this incomplete old withdrawal retains denial');
      expect(await gate.permits(owner: kRigOwner), isFalse);
      expect(fresh.isCurrent, isTrue);
    } finally {
      for (final hold in gate.holds) {
        if (!hold.release.isCompleted) hold.release.complete();
      }
      if (oldOutcome != null) await phase('outgoing cleanup', oldOutcome);
      outgoing?.dispose();
      await phase('fixture cleanup', f.dispose());
      ConsentAuthority.egressFrozen = false;
      CloudEgressGate.instance = previousGate;
    }
  });
}
