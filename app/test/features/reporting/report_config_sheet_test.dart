import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/reporting/report_request.dart';
import 'package:money_companion/features/reporting/ui/report_config_sheet.dart';
import 'package:money_companion/features/settings/settings_providers.dart';

void main() {
  Widget harness(void Function(ReportRequest?) onResult) {
    return ProviderScope(
      overrides: <Override>[
        // Keep settings pending → the sheet falls back to its defaults, no DB.
        userSettingsProvider
            .overrideWith((ref) => Completer<UserSettingsEntity>().future),
        accountsProvider.overrideWith((ref) async => <AccountEntity>[]),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async => onResult(await showReportConfigSheet(context)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders controls and returns a monthly all-accounts request',
      (tester) async {
    ReportRequest? result;
    await tester.pumpWidget(harness((r) => result = r));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Sheet is shown (English, the default MaterialApp locale).
    expect(find.text('Create financial report'), findsOneWidget);
    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('Privacy mode (mask amounts)'), findsOneWidget);

    await tester.ensureVisible(find.text('Generate report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate report'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.period, isA<MonthlyPeriod>());
    expect(result!.scope, isA<AllAccountsScope>());
    expect(result!.languageCode, 'ar'); // default when settings pending
  });

  testWidgets('selecting weekly yields a WeeklyPeriod request', (tester) async {
    ReportRequest? result;
    await tester.pumpWidget(harness((r) => result = r));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Generate report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate report'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.period, isA<WeeklyPeriod>());
  });
}
