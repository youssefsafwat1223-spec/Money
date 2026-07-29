import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/usecases/account_deletion.dart';
import 'package:money_companion/features/accounts/account_deletion_sheet.dart';

void main() {
  final now = DateTime.utc(2026, 7, 1);
  AccountEntity acc(String id, String currency) => AccountEntity(
        id: id,
        name: 'Acc $id',
        currency: currency,
        type: AccountType.bank,
        isDefault: false,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      );

  Future<AccountDeletionRequest?> openSheet(
    WidgetTester tester,
    AccountDeletionImpact impact,
  ) async {
    AccountDeletionRequest? popped;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              popped = await AccountDeletionSheet.show(ctx, impact);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return popped;
  }

  FilledButton confirmButton(WidgetTester tester) =>
      tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'حذف الحساب'),
      );

  testWidgets('confirm stays disabled until every subscription is resolved',
      (tester) async {
    final impact = AccountDeletionImpact(
      accountId: 'a',
      accountCurrency: 'SAR',
      transactionsToDetach: 3,
      cardsToArchive: 1,
      budgetsToArchive: 0,
      goals: const [],
      subscriptions: const [
        AccountDependent(
            id: 's1', name: 'Netflix', currency: 'SAR', amount: 50),
      ],
      successorCandidates: [acc('keep', 'SAR')],
    );

    await openSheet(tester, impact);

    // No decision yet → confirm disabled (subscription unresolved).
    expect(confirmButton(tester).onPressed, isNull);

    // Resolve the subscription as "archive".
    await tester.tap(find.byKey(const ValueKey('decision-s1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('أرشفة').last);
    await tester.pumpAndSettle();

    expect(confirmButton(tester).onPressed, isNotNull);
  });

  testWidgets('confirm returns a request with the chosen dispositions',
      (tester) async {
    final impact = AccountDeletionImpact(
      accountId: 'a',
      accountCurrency: 'SAR',
      transactionsToDetach: 0,
      cardsToArchive: 0,
      budgetsToArchive: 0,
      goals: const [
        AccountDependent(id: 'g1', name: 'Trip', currency: 'SAR', amount: 100),
      ],
      subscriptions: const [
        AccountDependent(id: 's1', name: 'Gym', currency: 'SAR', amount: 80),
      ],
      successorCandidates: [acc('keep', 'SAR')],
    );

    AccountDeletionRequest? request;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              request = await AccountDeletionSheet.show(ctx, impact);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Reassign the subscription to the compatible successor.
    await tester.tap(find.byKey(const ValueKey('decision-s1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('نقل إلى Acc keep').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'حذف الحساب'));
    await tester.pumpAndSettle();

    expect(request, isNotNull);
    // Goal defaulted to archive; subscription reassigned to 'keep'.
    expect(request!.goalChoices['g1']!.isArchive, isTrue);
    expect(request!.subscriptionChoices['s1']!.successorAccountId, 'keep');
  });

  testWidgets('a currency-incompatible successor is not offered',
      (tester) async {
    final impact = AccountDeletionImpact(
      accountId: 'a',
      accountCurrency: 'SAR',
      transactionsToDetach: 0,
      cardsToArchive: 0,
      budgetsToArchive: 0,
      goals: const [],
      subscriptions: const [
        AccountDependent(
            id: 's1', name: 'USD bill', currency: 'USD', amount: 9),
      ],
      successorCandidates: [acc('sar', 'SAR')], // only a SAR account exists
    );

    await openSheet(tester, impact);
    await tester.tap(find.byKey(const ValueKey('decision-s1')));
    await tester.pumpAndSettle();

    // The SAR successor must NOT be an option for a USD subscription.
    expect(find.text('نقل إلى Acc sar'), findsNothing);
    expect(find.text('أرشفة'), findsWidgets); // archive is the only option
  });
}
