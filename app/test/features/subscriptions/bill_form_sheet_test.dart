import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/domain/repositories/bill_repository.dart';
import 'package:money_companion/features/subscriptions/bill_form_sheet.dart';

class _BillRepository implements BillRepository {
  var saveCalls = 0;
  var recordPaymentCalls = 0;

  @override
  Future<BillEntity> save(BillEntity bill) async {
    saveCalls += 1;
    return bill;
  }

  @override
  Future<BillPaymentEntity> recordPayment(BillPaymentEntity payment) async {
    recordPaymentCalls += 1;
    return payment;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AccountRepository implements AccountRepository {
  @override
  Future<List<AccountEntity>> getAll() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BillEntity _bill({
  required DateTime dueDate,
  double? manualPaidAmount,
}) =>
    BillEntity(
      id: 'bill-1',
      name: 'Streaming',
      amountMoney: Money.fromLegacyReal(25, 'SAR'),
      currency: 'SAR',
      type: BillType.subscription,
      frequency: BillFrequency.monthly,
      nextDueDate: dueDate,
      reminderOn: true,
      isConfirmed: true,
      createdAt: DateTime.utc(2026, 7, 1),
      manualPaidMoney: manualPaidAmount == null
          ? null
          : Money.fromLegacyReal(manualPaidAmount, 'SAR'),
    );

Widget _app(_BillRepository repository, BillEntity bill) {
  return ProviderScope(
    overrides: [
      billRepositoryProvider.overrideWithValue(repository),
      accountRepositoryProvider.overrideWithValue(_AccountRepository()),
      accountsProvider.overrideWith((_) async => const []),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            height: 700,
            child: BillFormSheet(bill: bill),
          ),
        ),
      ),
    ),
  );
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

Future<void> _submit(WidgetTester tester) async {
  final button =
      find.byKey(const ValueKey('bill-save-button'), skipOffstage: false);
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('past due date is rejected at submit time', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    final repository = _BillRepository();
    await tester.pumpWidget(
      _app(
          repository,
          _bill(
              dueDate:
                  _dateOnly(DateTime.now()).subtract(const Duration(days: 1)))),
    );
    await tester.pumpAndSettle();

    await _submit(tester);

    expect(repository.saveCalls, 0);
    expect(find.text('اختار تاريخ استحقاق قادم أو اليوم.'), findsOneWidget);
  });

  testWidgets('today due date is accepted', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    final repository = _BillRepository();
    await tester.pumpWidget(
      _app(repository, _bill(dueDate: _dateOnly(DateTime.now()))),
    );
    await tester.pumpAndSettle();

    await _submit(tester);

    expect(repository.saveCalls, 1);
  });

  testWidgets('future due date is accepted', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    final repository = _BillRepository();
    await tester.pumpWidget(
      _app(
        repository,
        _bill(dueDate: _dateOnly(DateTime.now()).add(const Duration(days: 30))),
      ),
    );
    await tester.pumpAndSettle();

    await _submit(tester);

    expect(repository.saveCalls, 1);
  });

  testWidgets('manual paid amount rejects negative and zero values',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    for (final value in const [-1.0, 0.0]) {
      final repository = _BillRepository();
      await tester.pumpWidget(
        _app(
          repository,
          _bill(
            dueDate: _dateOnly(DateTime.now()),
            manualPaidAmount: value,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _submit(tester);

      expect(repository.saveCalls, 0);
      expect(find.text('اكتب مبلغ أكبر من صفر'), findsOneWidget);
    }
  });

  testWidgets('manual paid amount accepts a positive value', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    final repository = _BillRepository();
    await tester.pumpWidget(
      _app(repository, _bill(dueDate: _dateOnly(DateTime.now()))),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'مدفوع من الاشتراك يدويًا'),
      '1',
    );
    tester.testTextInput.hide();
    await tester.pump();

    await _submit(tester);

    expect(repository.saveCalls, 1);
  });
}
