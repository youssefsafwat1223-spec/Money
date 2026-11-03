import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/features/transactions/transaction_details_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../../tool/visual_parity/pending_age_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'pending-age-test-memory';
  @override
  Future<String?> readStoredKey() async => 'pending-age-test-memory';
}

Future<Map<String, Object>> snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final t in tables)
      t.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${t.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((r) => r.data)
          .toList()
  };
}

void main() {
  for (final key in visualParityPendingAgeKeys) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets(
            '$key $language dark=$dark actual pending age stays read-only',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          late AppDatabase db;
          await tester.runAsync(() async {
            final font = FontLoader('Vazirmatn');
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              font.addFont(
                  rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
            }
            await font.load();
            db = await AppDatabase.open(
                executor: NativeDatabase.memory(), keyStore: _Keys());
          });
          addTearDown(db.close);
          final parent = ProviderContainer(
              overrides: [appDatabaseProvider.overrideWithValue(db)]);
          addTearDown(parent.dispose);
          final original = parent.read(transactionRepositoryProvider);
          final before = await tester.runAsync(() => snapshot(db));
          final closed = visualParityPendingAgeEvents()['${key}Closed'] ?? 0;
          Future<bool>? opening;
          await tester.pumpWidget(UncontrolledProviderScope(
              container: parent,
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  home: Consumer(
                      builder: (context, ref, _) => Scaffold(
                          body: TextButton(
                              onPressed: () => opening = tester
                                  .runAsync(() => openVisualParityPendingAge(
                                      context, ref, key))
                                  .then((v) => v!),
                              child: const Text('Open age')))))));
          await tester.tap(find.text('Open age'));
          expect(await opening!, isTrue);
          await tester.pumpAndSettle();
          final screen = find.byType(TransactionDetailsScreen);
          final element = tester.element(screen);
          final navigator = Navigator.of(element);
          final child = ProviderScope.containerOf(element);
          final childDb = child.read(appDatabaseProvider);
          expect(identical(childDb, db), isFalse);
          final childBefore = await tester.runAsync(() => snapshot(childDb));
          final tx = await tester.runAsync(() => child
              .read(transactionRepositoryProvider)
              .getById('qa-pending-age-transaction'));
          expect(tx!.status, TransactionStatus.pending);
          expect(tx.amountMoney.minorUnits, 12345);
          expect(tx.currency, 'KWD');
          expect(DateTime.now().difference(tx.createdAt).inDays,
              key.endsWith('Today') ? 0 : 5);
          final l10n = AppL10n.of(element);
          double contrast(Color foreground, Color background) {
            final a = Color.alphaBlend(foreground, background).computeLuminance();
            final b = background.computeLuminance();
            return ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
          }
          final colors = Theme.of(element).extension<AppColors>()!;
          final badge = find.text(l10n.txdNeedsReview);
          final badgeElement = tester.element(badge);
          Color? badgeBackground;
          badgeElement.visitAncestorElements((ancestor) {
            if (ancestor.widget case DecoratedBox(decoration: final BoxDecoration decoration)) {
              if (decoration.color != null) { badgeBackground = decoration.color; return false; }
            }
            return true;
          });
          expect(badgeBackground, isNotNull);
          final paintedBadge = Color.alphaBlend(badgeBackground!, colors.bg);
          final badgeParagraph = tester.renderObject<RenderParagraph>(badge);
          expect(contrast(badgeParagraph.text.style!.color!, paintedBadge), greaterThanOrEqualTo(4.5),
            reason: 'Pending review badge text stays readable on its actual tinted fill');
          final label = key.endsWith('Today')
              ? l10n.txdPendingToday
              : l10n.txdPendingDays(5);
          await tester.scrollUntilVisible(find.text(label), 180,
              scrollable: find.byType(Scrollable).first);
          await tester.pumpAndSettle();
          expect(find.text(label).hitTestable(), findsOneWidget);
          final ageParagraph = tester.renderObject<RenderParagraph>(find.text(label));
          expect(contrast(ageParagraph.text.style!.color!, colors.surface), greaterThanOrEqualTo(4.5),
            reason: 'Pending age copy stays readable on the detail surface');
          expect(tester.takeException(), isNull);
          expect(await tester.runAsync(() => snapshot(childDb)), childBefore);
          expect(await tester.runAsync(() => snapshot(db)), before);
          expect(
              identical(parent.read(transactionRepositoryProvider), original),
              isTrue);
          navigator.pop();
          for (var i = 0;
              i < 40 &&
                  (visualParityPendingAgeEvents()['${key}Closed'] ?? 0) ==
                      closed;
              i++) {
            await tester.pump(const Duration(milliseconds: 60));
            await tester.runAsync(() async =>
                Future<void>.delayed(const Duration(milliseconds: 10)));
          }
          await tester.pumpAndSettle();
          expect(visualParityPendingAgeEvents()['${key}Closed'], closed + 1);
          expect(find.text('Open age'), findsOneWidget);
          expect(await tester.runAsync(() => snapshot(db)), before);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
  testWidgets('unknown key never resolves database providers', (tester) async {
    var databaseReads = 0;
    final parent = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWith((ref) {
        databaseReads++;
        throw StateError('Unknown fixture must not access a database');
      })
    ]);
    addTearDown(parent.dispose);
    Future<bool>? request;
    await tester.pumpWidget(UncontrolledProviderScope(
        container: parent,
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => Scaffold(
                    body: TextButton(
                        onPressed: () => request =
                            openVisualParityPendingAge(context, ref, 'unknown'),
                        child: const Text('Unknown age')))))));
    await tester.tap(find.text('Unknown age'));
    expect(await request!, isFalse);
    expect(databaseReads, 0);
    expect(find.byType(TransactionDetailsScreen), findsNothing);
  });
  testWidgets('disk parent is rejected before child creation', (tester) async {
    final dir = await tester
        .runAsync(() => Directory.systemTemp.createTemp('pending-age-parent-'));
    final db = (await tester.runAsync(() => AppDatabase.open(
        executor: NativeDatabase(File('${dir!.path}/qa.sqlite')),
        keyStore: _Keys())))!;
    final parent = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)]);
    Object? rejected;
    final before = await tester.runAsync(() => snapshot(db));
    final events = visualParityPendingAgeEvents();
    await tester.pumpWidget(UncontrolledProviderScope(
        container: parent,
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => Scaffold(
                    body: TextButton(
                        onPressed: () async {
                          try {
                            await openVisualParityPendingAge(
                                context, ref, 'pendingAgeToday');
                          } catch (error) {
                            rejected = error;
                          }
                        },
                        child: const Text('Open file')))))));
    await tester.tap(find.text('Open file'));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    expect(rejected, isA<StateError>());
    expect(await tester.runAsync(() => snapshot(db)), before);
    expect(visualParityPendingAgeEvents(), events);
    expect(tester.takeException(), isNull);
    expect(find.byType(TransactionDetailsScreen), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    parent.dispose();
    await tester.runAsync(db.close);
    await tester.runAsync(() => dir!.delete(recursive: true));
  });
}
