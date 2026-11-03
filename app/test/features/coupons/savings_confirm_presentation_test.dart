import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';
import 'package:money_companion/features/coupons/savings_confirm_sheet.dart';
import 'package:money_companion/features/coupons/savings_math.dart';
import 'package:money_companion/features/coupons/savings_providers.dart';
import 'package:money_companion/features/coupons/savings_repository.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'savings-confirm-memory-only';
  @override
  Future<String?> readStoredKey() async => 'savings-confirm-memory-only';
}

class _ControlledSavings extends SavingsRepository {
  _ControlledSavings(super.db);

  Completer<void>? pending;
  bool fail = false;
  int calls = 0;

  @override
  Future<String?> record(
    SavingsOutcome outcome, {
    required String couponId,
    String? merchantId,
    String? clickId,
    DateTime? occurredAt,
  }) async {
    calls++;
    if (pending != null) await pending!.future;
    if (fail) throw StateError('private-synthetic-storage-failure');
    return super.record(outcome,
        couponId: couponId,
        merchantId: merchantId,
        clickId: clickId,
        occurredAt: occurredAt);
  }
}

CouponOffer _offer({bool computable = true}) => CouponOffer(
      id: 'qa-computable-savings',
      slug: 'qa-computable-savings',
      partnerName: 'Local QA',
      titleAr: 'عرض اختبار',
      titleEn: 'Test offer',
      descriptionAr: 'اختبار محلي',
      descriptionEn: 'Local test',
      redemptionType: CouponRedemptionType.code,
      category: const CouponCategory(key: 'qa', labelAr: 'اختبار'),
      validFrom: DateTime.utc(2020),
      benefitType: computable ? 'percent' : 'free_shipping',
      discountBps: computable ? 1000 : null,
      benefitCurrency: 'KWD',
    );

Future<AppL10n> _open(WidgetTester tester, _ControlledSavings repository,
    String language, bool dark,
    {bool computable = true}) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [savingsRepositoryProvider.overrideWithValue(repository)],
    child: MaterialApp(
      locale: Locale(language),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      theme: dark ? AppTheme.dark : AppTheme.light,
      home: Scaffold(
          body: Consumer(
              builder: (context, ref, _) => TextButton(
                    onPressed: () => showSavingsConfirmSheet(
                        context, ref, _offer(computable: computable)),
                    child: const Text('Open savings'),
                  ))),
    ),
  ));
  await tester.tap(find.text('Open savings'));
  await tester.pumpAndSettle();
  final l10n = AppL10n.of(tester.element(find.byType(TextField)));
  await tester.enterText(find.byType(TextField), '250.000');
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
  return l10n;
}

Future<void> _flush(WidgetTester tester) async {
  await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 80)));
  await tester.pumpAndSettle();
}

void main() {
  late AppDatabase db;
  late _ControlledSavings repository;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _Keys(),
        initialLanguage: 'en');
    repository = _ControlledSavings(db);
  });
  tearDown(() async => db.close());

  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('savings pending blocks duplicate save $language dark$dark',
          (tester) async {
        final gate = repository.pending = Completer<void>();
        final l10n = await _open(tester, repository, language, dark);
        final save =
            find.widgetWithText(FilledButton, l10n.savingsConfirmAction);
        await tester.tap(save);
        await tester.tap(save);
        await tester.pump();
        final pendingCalls = repository.calls;
        final enabled =
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
                null;
        final inputEnabled =
            tester.widget<TextField>(find.byType(TextField)).enabled;
        final spinner =
            find.byType(CircularProgressIndicator).evaluate().length;
        gate.complete();
        await _flush(tester);
        final rows = await tester.runAsync(repository.history);
        expect(pendingCalls, 1);
        expect(enabled, isFalse);
        expect(inputEnabled, isFalse);
        expect(spinner, 1);
        expect(rows, hasLength(1));
        expect(rows!.single.amountMinor, 25000);
        expect(rows.single.currency, 'KWD');
        expect(rows.single.evidence, SavingsEvidence.userConfirmed);
        expect(find.text('Open savings'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          'savings failure keeps exact input and permits retry $language dark$dark',
          (tester) async {
        repository.fail = true;
        final l10n = await _open(tester, repository, language, dark);
        await tester
            .tap(find.widgetWithText(FilledButton, l10n.savingsConfirmAction));
        await _flush(tester);
        final failure = tester.takeException();
        final shownError = find.text(l10n.txnError).evaluate().isNotEmpty;
        final input =
            tester.widget<TextField>(find.byType(TextField)).controller!.text;
        final canRetry =
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
                null;
        final before = await tester.runAsync(repository.history);
        repository.fail = false;
        await tester
            .tap(find.widgetWithText(FilledButton, l10n.savingsConfirmAction));
        await _flush(tester);
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
        final after = await tester.runAsync(repository.history);
        expect(failure, isNull);
        expect(shownError, isTrue);
        expect(find.textContaining('private-synthetic'), findsNothing);
        expect(input, '250.000');
        expect(canRetry, isTrue);
        expect(before, isEmpty);
        expect(after, hasLength(1));
        expect(after!.single.amountMinor, 25000);
        expect(repository.calls, 2);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          'savings uncomputable benefit remains disabled $language dark$dark',
          (tester) async {
        final l10n =
            await _open(tester, repository, language, dark, computable: false);
        expect(find.text(l10n.savingsCannotCompute), findsOneWidget);
        expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull);
        expect(repository.calls, 0);
        expect(await tester.runAsync(repository.history), isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
