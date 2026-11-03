import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/bill_repository.dart';
import 'package:money_companion/features/subscriptions/bill_form_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Bills implements BillRepository {
  final saved = <BillEntity>[];
  final payments = <BillPaymentEntity>[];
  @override
  Future<BillEntity> save(BillEntity bill) async { saved.add(bill); return bill; }
  @override
  Future<BillPaymentEntity> recordPayment(BillPaymentEntity payment) async {
    payments.add(payment); return payment;
  }
  @override
  Future<BillPaymentEntity> createAndRecordPayment({required BillEntity bill,
      required BillPaymentEntity payment}) async {
    saved.add(bill); payments.add(payment); return payment;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BillEntity _original() => BillEntity(id: 'synthetic-bill', name: 'Synthetic bill',
  amountMoney: Money(12345, 'KWD'), currency: 'KWD', type: BillType.installment,
  frequency: BillFrequency.custom, customIntervalDays: 7,
  nextDueDate: DateTime.now().add(const Duration(days: 30)),
  reminderOn: true, isConfirmed: true, createdAt: DateTime.utc(2026, 1, 1),
  manualPaidMoney: Money(2345, 'KWD'), totalInstallments: 12, paidCount: 2,
  totalPurchaseMoney: Money(500000, 'KWD'), lenderName: 'Synthetic lender',
  interestRate: .05, accountId: 'synthetic-account', status: BillStatus.active,
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (!tester.binding.hasScheduledFrame) return;
  }
}

Future<AppL10n> _open(WidgetTester tester, _Bills repository, BillEntity bill,
    String language) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = const FakeViewPadding(bottom: 250);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(overrides: [
    billRepositoryProvider.overrideWithValue(repository),
    accountsProvider.overrideWith((ref) async => const []),
  ], child: MaterialApp(theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
    locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates,
    home: Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () => BillFormSheet.show(context, bill: bill),
      child: const Text('Open bill'),
    ))),
  )));
  await tester.tap(find.text('Open bill'));
  await _settle(tester);
  return AppL10n.of(tester.element(find.byType(BillFormSheet)));
}

Finder _field(String label) => find.widgetWithText(TextFormField, label);
Future<void> _enter(WidgetTester tester, String label, String value) async {
  final scroll = find.descendant(of: find.byType(BillFormSheet), matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(_field(label), 220, scrollable: scroll);
  await tester.enterText(_field(label), value);
  tester.testTextInput.hide();
  await _settle(tester);
}

Future<void> _save(WidgetTester tester) async {
  final save = find.byKey(const ValueKey('bill-save-button'));
  final scroll = find.descendant(of: find.byType(BillFormSheet), matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(save, 220, scrollable: scroll);
  await _settle(tester);
  await tester.tap(save);
  await _settle(tester);
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final spec in [
      ('name', ''), ('amount', '-12'), ('amount', '0'), ('amount', '12.3456'),
      ('manual', '-2'), ('manual', '0'), ('days', '1.5'), ('days', '-3'), ('days', '0'),
    ]) {
      testWidgets('bill raw ${spec.$1} input ${spec.$2} cannot pass offstage Save in $language', (tester) async {
        final repository = _Bills();
        final l10n = await _open(tester, repository, _original(), language);
        final label = switch (spec.$1) {
          'name' => l10n.bfBillName, 'amount' => l10n.bdgAmount,
          'manual' => l10n.bfManuallyPaidAmount, _ => l10n.bfEveryHowManyDays,
        };
        await _enter(tester, label, spec.$2);
        expect(tester.widget<TextFormField>(_field(label)).controller!.text, spec.$2);
        final save = find.byKey(const ValueKey('bill-save-button'));
        await tester.scrollUntilVisible(save, 220,
            scrollable: find.descendant(of: find.byType(BillFormSheet), matching: find.byType(Scrollable)).first);
        await _settle(tester);
        if (spec.$1 != 'days') {
          expect(_field(label), findsNothing,
              reason: 'the original retained field must actually be offstage');
        }
        await tester.tap(save);
        await _settle(tester);
        expect(repository.saved, isEmpty);
        expect(repository.payments, isEmpty);
        expect(find.byIcon(AppLucideIcons.alertCircle), findsOneWidget);
        expect(find.byType(BillFormSheet), findsOneWidget);
        await tester.pump(const Duration(seconds: 4));
        await _settle(tester);
        final reverse = find.descendant(of: find.byType(BillFormSheet), matching: find.byType(Scrollable)).first;
        await tester.scrollUntilVisible(_field(label), -220, scrollable: reverse);
        expect(tester.widget<TextFormField>(_field(label)).controller!.text, spec.$2);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('bill Arabic amount, manual delta and custom integer stay exact in $language', (tester) async {
      final repository = _Bills();
      final original = _original();
      final l10n = await _open(tester, repository, original, language);
      await _enter(tester, l10n.bdgAmount, '٢٣٫٤٥٦');
      await _enter(tester, l10n.bfManuallyPaidAmount, '٥٫٦٧٨');
      await _enter(tester, l10n.bfEveryHowManyDays, '١٥');
      await _save(tester);
      final saved = repository.saved.single;
      expect(saved.amountMoney, Money(23456, 'KWD'));
      expect(saved.manualPaidMoney, Money(5678, 'KWD'));
      expect(saved.customIntervalDays, 15);
      expect(saved.id, original.id);
      expect(saved.name, original.name);
      expect(saved.currency, original.currency);
      expect(saved.accountId, original.accountId);
      expect(saved.nextDueDate, original.nextDueDate);
      expect(saved.createdAt, original.createdAt);
      expect(saved.type, original.type);
      expect(saved.frequency, original.frequency);
      expect(saved.reminderOn, original.reminderOn);
      expect(saved.isConfirmed, original.isConfirmed);
      expect(saved.status, original.status);
      expect(saved.totalInstallments, original.totalInstallments);
      expect(saved.paidCount, original.paidCount);
      expect(saved.totalPurchaseMoney, original.totalPurchaseMoney);
      expect(saved.lenderName, original.lenderName);
      expect(saved.interestRate, original.interestRate);
      final payment = repository.payments.single;
      expect(payment.billId, original.id);
      expect(payment.amountMoney, Money(3333, 'KWD'));
      expect(payment.currency, 'KWD');
      expect(find.byType(BillFormSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
