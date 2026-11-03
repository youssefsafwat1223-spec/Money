import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

// A status read only. No registration service, session, consent or DB exists.
class _PresentationService implements CaptureDeviceRegistrationService {
  _PresentationService(CaptureRegistrationPhase phase)
      : value = ValueNotifier(CaptureRegistrationStatus(phase));
  final ValueNotifier<CaptureRegistrationStatus> value;
  int retries = 0;
  @override
  ValueListenable<CaptureRegistrationStatus> get status => value;
  @override
  Future<void> retry() async { retries++; }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.9411764705882353]) {
        for (final phase in CaptureRegistrationPhase.values) {
          testWidgets('registration $phase fits375 $language dark$dark scale$scale without grant', (tester) async {
            tester.view.physicalSize = const Size(375, 667);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final service = _PresentationService(phase);
            addTearDown(service.value.dispose);
            await tester.runAsync(() async {
              final font = FontLoader('Vazirmatn');
              for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
              }
              await font.load();
            });
            await tester.pumpWidget(ProviderScope(overrides: [
              captureDeviceRegistrationServiceProvider.overrideWithValue(service),
            ], child: MaterialApp(theme: dark ? AppTheme.dark : AppTheme.light,
              locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
              localizationsDelegates: AppL10n.localizationsDelegates,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
              home: const Scaffold(body: Padding(padding: EdgeInsets.all(20),
                child: SmartAnalysisRegistrationStatus())),
            )));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 700));
            final l10n = AppL10n.of(tester.element(find.byType(SmartAnalysisRegistrationStatus)));
            final label = switch (phase) {
              CaptureRegistrationPhase.connecting => l10n.smartConsentStatusConnecting,
              CaptureRegistrationPhase.connected => l10n.smartConsentStatusConnected,
              CaptureRegistrationPhase.failed => l10n.smartConsentStatusFailed,
              CaptureRegistrationPhase.notRequested => null,
            };
            if (label != null) {
              final finder = find.text(label);
              expect(finder, findsOneWidget);
              final rect = tester.getRect(finder);
              expect(rect.left, greaterThanOrEqualTo(20));
              expect(rect.right, lessThanOrEqualTo(355));
            }
            expect(tester.takeException(), isNull);
            expect(service.retries, 0);
          });
        }
      }
    }
  }
}
