import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/budgets/budgets_providers.dart';
import 'package:money_companion/features/budgets/budgets_screen.dart';
import 'package:money_companion/features/common/app_error_state.dart';
import 'package:money_companion/features/reports/reports_providers.dart';
import 'package:money_companion/features/reports/reports_screen.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory';
  @override
  Future<String?> readStoredKey() async => 'memory';
}

class _FailingTransactions extends TransactionsListNotifier {
  _FailingTransactions(this.read);
  final Future<TransactionsView> Function() read;
  @override
  Future<TransactionsView> build() => read();
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
  });
  tearDown(() async => db.close());

  for (final language in ['ar', 'en']) {
    for (final surface in ['reports', 'budgets', 'activity']) {
      testWidgets('$surface error clears the status inset and Retry remains usable in $language', (tester) async {
        await tester.runAsync(() async {
          final loader = FontLoader('Vazirmatn');
          for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
            loader.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
          }
          await loader.load();
        });
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 62, bottom: 34);
        tester.view.viewPadding = const FakeViewPadding(top: 62, bottom: 34);
        addTearDown(tester.view.reset);
        var reads = 0;
        Future<T> failure<T>() async {
          reads++;
          throw StateError('synthetic local read failure');
        }
        final Widget screen = switch (surface) {
          'reports' => const ReportsScreen(),
          'budgets' => const BudgetsScreen(),
          _ => const TransactionsScreen(),
        };
        await tester.pumpWidget(ProviderScope(overrides: [
          appDatabaseProvider.overrideWithValue(db),
          if (surface == 'reports')
            reportsProvider.overrideWith((ref) => failure()),
          if (surface == 'budgets')
            budgetsViewProvider.overrideWith((ref) => failure()),
          if (surface == 'activity')
            transactionsListProvider.overrideWith(() =>
                _FailingTransactions(() => failure<TransactionsView>())),
        ], child: MaterialApp(
          theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
          locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: screen,
        )));
        await tester.pumpAndSettle();
        final error = find.byType(AppErrorState);
        expect(error, findsOneWidget);
        final icon = find.descendant(of: error,
            matching: find.byIcon(AppLucideIcons.alertTriangle));
        final box = find.ancestor(of: icon, matching: find.byType(Container)).first;
        expect(tester.getTopLeft(box).dy, greaterThanOrEqualTo(62 + 16));
        final l10n = AppL10n.of(tester.element(error));
        final retry = find.text(l10n.startRetry);
        expect(retry.hitTestable(), findsOneWidget);
        expect(tester.getBottomRight(retry).dy, lessThanOrEqualTo(667 - 34));
        final beforeReads = reads;
        final beforeWrites = (await db.customSelect(
            'SELECT total_changes() AS writes').getSingle()).read<int>('writes');
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(reads, beforeReads + 1);
        expect((await db.customSelect('SELECT total_changes() AS writes')
            .getSingle()).read<int>('writes'), beforeWrites);
        expect(tester.getTopLeft(box).dy, greaterThanOrEqualTo(62 + 16));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }
}
