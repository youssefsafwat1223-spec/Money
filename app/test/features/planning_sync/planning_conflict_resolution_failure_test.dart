import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/glass_scaffold_messenger.dart';
import 'package:money_companion/features/planning_sync/planning_conflicts_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

// Fails at the service boundary; no real resolver, DB, authority or network.
class _FailingResolver implements UniversalConflictResolver {
  _FailingResolver(this.outcome);
  final String outcome;
  Completer<bool> gate = Completer<bool>();
  int calls = 0;
  Future<bool> _fail(String type, String id) async {
    expect(type, 'goal');
    expect(id, 'visual-conflict');
    calls++;
    await gate.future;
    if (outcome == 'false') return false;
    throw StateError('private_resolution_diagnostic');
  }

  @override
  Future<void> resolveKeepLocal(String type, String id) async {
    await _fail(type, id);
  }

  @override
  Future<bool> resolveKeepRemote(String type, String id) => _fail(type, id);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unrequested_resolver_operation');
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final operation in ['localError', 'remoteError', 'remoteFalse']) {
        testWidgets('resolution failure $language dark$dark $operation',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.runAsync(() async {
            final font = FontLoader('Vazirmatn');
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              font.addFont(
                  rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
            }
            await font.load();
          });
          final resolver =
              _FailingResolver(operation == 'remoteFalse' ? 'false' : 'error');
          const conflict = SyncConflict(
              entityType: 'goal', localId: 'visual-conflict', label: 'QA goal');
          await tester.pumpWidget(ProviderScope(
              overrides: [
                conflictsProvider.overrideWith((ref) async => const [conflict]),
                conflictResolverProvider.overrideWithValue(resolver),
              ],
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  builder: (context, child) =>
                      GlassScaffoldMessenger(child: child!),
                  home: const Scaffold(body: PlanningConflictsSheet()))));
          await tester.pumpAndSettle();
          final l10n =
              AppL10n.of(tester.element(find.byType(PlanningConflictsSheet)));
          final button = find.widgetWithText(
              OutlinedButton,
              operation == 'localError'
                  ? l10n.conflictKeepMine
                  : l10n.conflictKeepCloud);
          expect(button.hitTestable(), findsOneWidget);
          await tester.tap(button);
          await tester.pump();
          expect(resolver.calls, 1);
          for (final button in tester
              .widgetList<OutlinedButton>(find.byType(OutlinedButton))) {
            expect(button.onPressed, isNull);
          }
          resolver.gate.complete(false);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text(l10n.annTryAgainSoon), findsOneWidget);
          expect(find.text('QA goal'), findsOneWidget);
          expect(find.textContaining('private_resolution'), findsNothing);
          expect(find.text(l10n.pcsKeptMine), findsNothing);
          expect(find.text(l10n.conflictKeptCloud), findsNothing);
          expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
          final label =
              find.descendant(of: button, matching: find.byType(Text));
          final context = tester.element(button);
          expect(tester.renderObject<RenderParagraph>(label).text.style!.color,
              dark ? context.colors.textPrimary : context.colors.cta);
          resolver.gate = Completer<bool>();
          await tester.tap(button);
          await tester.pump();
          expect(resolver.calls, 2);
          resolver.gate.complete(false);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('QA goal'), findsOneWidget);
          await tester.pump(const Duration(seconds: 4));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
