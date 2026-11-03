import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/qirsh_visuals.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/features/common/app_card.dart';
import 'package:money_companion/features/common/app_empty_state.dart';
import 'package:money_companion/features/planning_sync/planning_conflicts_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final language in ['ar', 'en']) {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      for (final width in [375.0, 402.0]) {
        for (final outcome in ['loading', 'error', 'empty']) {
          testWidgets('public conflicts sheet $language ${theme.brightness.name} width$width $outcome preserves read state and original copy',
              (tester) async {
            tester.view.physicalSize = Size(width, 667);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.runAsync(() async {
              final fonts = FontLoader('Vazirmatn');
              for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
              }
              await fonts.load();
            });
            final read = Completer<List<SyncConflict>>();
            var readCount = 0;
            var resolverReads = 0;
            await tester.pumpWidget(ProviderScope(overrides: [
              conflictsProvider.overrideWith((ref) {
                readCount++;
                return read.future;
              }),
              conflictResolverProvider.overrideWith((ref) {
                resolverReads++;
                throw StateError('Read-state presentation must not resolve conflicts');
              }),
            ], child: MaterialApp(theme: theme, locale: Locale(language),
              supportedLocales: AppL10n.supportedLocales,
              localizationsDelegates: AppL10n.localizationsDelegates,
              home: Scaffold(body: Builder(builder: (context) => TextButton(
                onPressed: () => PlanningConflictsSheet.show(context),
                child: const Text('Open actual conflicts sheet'),
              ))),
            )));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Open actual conflicts sheet'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(find.byType(PlanningConflictsSheet), findsOneWidget);
            final sheet = find.byType(PlanningConflictsSheet);
            final l10n = AppL10n.of(tester.element(sheet));
            expect(find.descendant(of: sheet,
                matching: find.byType(CircularProgressIndicator)), findsOneWidget);
            expect(find.text(l10n.pcsNoConflicts), findsNothing,
                reason: 'An unresolved read must not claim successful sync.');

            if (outcome == 'error') {
              read.completeError(StateError('synthetic conflict read failure'));
              await tester.pumpAndSettle();
              expect(find.text(l10n.pcsLoadFailed), findsOneWidget);
              expect(find.text(l10n.pcsNoConflicts), findsNothing);
              expect(find.text(l10n.pcsAllSynced), findsNothing);
              expect(find.descendant(of: sheet,
                  matching: find.byIcon(AppLucideIcons.alertTriangle)), findsOneWidget);
              final card = tester.widget<AppCard>(find.descendant(of: sheet,
                  matching: find.byType(AppCard)));
              expect(card.variant, AppCardVariant.danger);
              expect(find.ancestor(of: find.text(l10n.pcsLoadFailed),
                  matching: find.byWidgetPredicate((w) => w is Semantics &&
                      w.properties.liveRegion == true)), findsOneWidget);
            } else if (outcome == 'empty') {
              read.complete(const []);
              await tester.pumpAndSettle();
              expect(find.text(l10n.pcsNoConflicts), findsOneWidget);
              expect(find.text(l10n.pcsAllSynced), findsOneWidget);
              expect(find.text(l10n.pcsLoadFailed), findsNothing);
              final empty = tester.widget<AppEmptyState>(find.descendant(
                  of: sheet, matching: find.byType(AppEmptyState)));
              expect(empty.primaryLabel, isNull);
              expect(empty.secondaryLabel, isNull);
              expect(find.descendant(of: sheet,
                  matching: find.byWidgetPredicate((w) => w is QirshIllustration &&
                      w.name == 'dataTransfer' && w.width == 160 && w.height == 120)),
                  findsOneWidget);
            }
            expect(find.text(l10n.conflictKeepMine), findsNothing);
            expect(find.text(l10n.conflictKeepCloud), findsNothing);
            expect(readCount, 1);
            expect(resolverReads, 0,
                reason: 'Presenting/dismissing a read outcome must not obtain resolution authority.');
            expect(tester.takeException(), isNull);
            Navigator.of(tester.element(sheet)).pop();
            await tester.pumpAndSettle();
            expect(find.byType(PlanningConflictsSheet), findsNothing);
            expect(find.text('Open actual conflicts sheet'), findsOneWidget);
            expect(resolverReads, 0);
            if (!read.isCompleted) read.complete(const []);
            await tester.pump();
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }
}
