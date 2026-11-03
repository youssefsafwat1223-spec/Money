// Offline presentation QA only. Never initializes registration or grants consent.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_spacing.dart';
import 'package:money_companion/core/utils/l10n_ext.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/common/app_card.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';
import 'package:money_companion/features/onboarding/onboarding_consent_steps.dart';
import 'package:money_companion/features/settings/settings_providers.dart';

const visualParityRegistrationStateKeys = <String>[
  'registrationConnecting',
  'registrationConnected',
  'registrationFailed',
  'registrationNotRequested',
  'readinessConnecting',
  'readinessConnected',
  'readinessFailed',
];

final _events = <String, int>{};
Map<String, int> visualParityRegistrationStateEvents() =>
    Map.unmodifiable(_events);

/// A status value only: no real constructor, session, consent writer or client.
/// Even an accidental Retry/Continue fails closed rather than doing any work.
class _PresentationStatus implements CaptureDeviceRegistrationService {
  _PresentationStatus(this.key, CaptureRegistrationPhase phase)
      : value = ValueNotifier(CaptureRegistrationStatus(phase));
  final String key;
  final ValueNotifier<CaptureRegistrationStatus> value;

  @override
  ValueListenable<CaptureRegistrationStatus> get status => value;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    _events.update(key, (count) => count + 1, ifAbsent: () => 1);
    throw StateError('registration_presentation_operation_forbidden');
  }
}

Future<bool> openVisualParityRegistrationState(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityRegistrationStateKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('registration_presentation_requires_offline_debug');
  }
  final database = ref.read(appDatabaseProvider);
  final databases = await database.customSelect('PRAGMA database_list').get();
  if (!databases.any((row) =>
      row.read<String>('name') == 'main' && row.read<String>('file').isEmpty)) {
    throw StateError('registration_presentation_requires_memory_database');
  }
  // This is a read. The copy below is consumed solely by the readiness widget;
  // it is never saved and does not represent an actual Cloud grant.
  final settings = await ref.read(userSettingsRepositoryProvider).getSettings();
  if (!context.mounted) return false;
  final phase = key.endsWith('NotRequested')
      ? CaptureRegistrationPhase.notRequested
      : key.endsWith('Connecting')
          ? CaptureRegistrationPhase.connecting
          : key.endsWith('Connected')
              ? CaptureRegistrationPhase.connected
              : CaptureRegistrationPhase.failed;
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
    builder: (_) => _RegistrationScope(
        keyName: key, phase: phase, database: database, settings: settings),
  )));
  return true;
}

class _RegistrationScope extends StatefulWidget {
  const _RegistrationScope(
      {required this.keyName,
      required this.phase,
      required this.database,
      required this.settings});
  final String keyName;
  final CaptureRegistrationPhase phase;
  final AppDatabase database;
  final UserSettingsEntity settings;
  @override
  State<_RegistrationScope> createState() => _RegistrationScopeState();
}

class _RegistrationScopeState extends State<_RegistrationScope> {
  late final ProviderContainer _container;
  @override
  void initState() {
    super.initState();
    // This independent presentation root is necessary because the production
    // registration notifier does not declare scoped service dependencies.
    // Its unchanged implementation still reads the real status interface.
    _container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(widget.database),
      captureDeviceRegistrationServiceProvider.overrideWith((ref) {
        final status = _PresentationStatus(widget.keyName, widget.phase);
        ref.onDispose(status.value.dispose);
        return status;
      }),
      userSettingsProvider.overrideWith((ref) async =>
          widget.settings.copyWith(cloudConsentState: ConsentState.accepted)),
    ]);
  }

  @override
  void dispose() {
    _container.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
        container: _container,
        child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) =>
                    _RegistrationPresentation(keyName: widget.keyName))),
      );
}

class _RegistrationPresentation extends StatelessWidget {
  const _RegistrationPresentation({required this.keyName});
  final String keyName;

  @override
  Widget build(BuildContext context) {
    final readiness = keyName.startsWith('readiness');
    return Scaffold(
      backgroundColor: readiness ? AppBrandBlue.deep : null,
      appBar: AppBar(
        title: Text(
          readiness ? context.l10n.onbReadyTitle : context.l10n.smartConsentTitle,
          style: readiness ? const TextStyle(color: Colors.white) : null,
        ),
        backgroundColor: readiness ? AppBrandBlue.deep : null,
        foregroundColor: readiness ? Colors.white : null,
        leading: BackButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
      ),
      body: SafeArea(
          child: readiness
              ? OnboardingReadinessStep(
                  onDark: true,
                  onDone: () {
                    _events.update(keyName, (count) => count + 1,
                        ifAbsent: () => 1);
                    throw StateError(
                        'registration_presentation_continue_forbidden');
                  })
              : keyName == 'registrationNotRequested'
                  ? const SmartAnalysisRegistrationStatus()
                  : const SingleChildScrollView(
                      padding: EdgeInsets.all(AppSpacing.gutter),
                      child: AppCard(child: SmartAnalysisRegistrationStatus()))),
    );
  }
}
