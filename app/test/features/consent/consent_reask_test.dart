import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';

import 'consent_test_harness.dart';

// §4.6 "a new device re-asks": an onboarded account admitted into a fresh replica
// (consent unset) is asked through the sheet before any egress.

class _Host extends ConsumerStatefulWidget {
  const _Host({required this.seen, required this.markSeen});
  final Future<bool> Function() seen;
  final Future<void> Function() markSeen;

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => maybeReaskConsent(
          context,
          ref,
          seen: widget.seen,
          markSeen: widget.markSeen,
        ));
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox());
}

void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;
  var asked = false;
  var markCalls = 0;

  Future<void> pump(WidgetTester tester,
      {bool seen = false, String locale = 'en'}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    markCalls = 0;
    asked = seen;
    await tester.pumpWidget(consentApp(
      overrides: consentOverrides(repo, service),
      home: _Host(
        seen: () async => asked,
        markSeen: () async {
          markCalls++;
          asked = true;
        },
      ),
      locale: locale,
    ));
    await tester.pumpAndSettle();
  }

  setUp(() {
    repo = FakeSettingsRepository();
    service = FakeRegistrationService();
  });

  testWidgets('fresh replica, consent unset, never asked: the sheet opens and '
      'nothing is saved or sent before the answer (EN)', (tester) async {
    await pump(tester);
    expect(find.text('Smart Analysis & Cloud Sync'), findsOneWidget);
    expect(find.text('Enable Cloud Sync'), findsOneWidget);
    expect(repo.saveCalls, 0);
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    expect(repo.settings.aiConsentState, ConsentState.unset);
    expect(service.retryCalls, 0);
    expect(service.syncCalls, 0);
    expect(markCalls, 0, reason: 'not answered yet');
  });

  testWidgets('re-ask renders in Arabic', (tester) async {
    await pump(tester, locale: 'ar');
    expect(find.text('التحليل الذكي والمزامنة السحابية'), findsOneWidget);
    expect(find.text('تفعيل المزامنة السحابية'), findsOneWidget);
  });

  testWidgets('"Not now" records the question as asked, writes nothing (stays '
      'denied)', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(markCalls, 1);
    expect(repo.saveCalls, 0);
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    expect(service.syncCalls + service.retryCalls, 0);
  });

  testWidgets('swipe-dismiss does not record it: it is asked again next time',
      (tester) async {
    await pump(tester);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(markCalls, 0);
  });

  testWidgets('already asked on this device: no sheet', (tester) async {
    await pump(tester, seen: true);
    expect(find.text('Smart Analysis & Cloud Sync'), findsNothing);
  });

  testWidgets('any explicit answer already on the replica: no sheet',
      (tester) async {
    repo.settings =
        repo.settings.copyWith(cloudConsentState: ConsentState.declined);
    await pump(tester);
    expect(find.text('Smart Analysis & Cloud Sync'), findsNothing);
  });
}
