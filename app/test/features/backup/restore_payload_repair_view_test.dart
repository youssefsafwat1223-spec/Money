import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/planning_restore_preflight.dart';
import 'package:money_companion/data/db/planning_currency_repair.dart'
    show PlanningRepairMode;
import 'package:money_companion/features/backup/restore_payload_repair_view.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/qirsh_visuals.dart';
import 'package:money_companion/features/common/app_card.dart';
import 'package:money_companion/l10n/app_localizations.dart';

// MALI-026 (Phase-8 B8-2.10 §6) — the restore-payload repair UX emits a decision
// scoped to the PAYLOAD fingerprint (not the live dataset) and supports
// global/per-row/cancel.

void main() {
  const rows = [
    RestorePlanningRow(id: 'b1', isGoal: false, legacyAmount: 100.0),
    RestorePlanningRow(
        id: 'g1', isGoal: true, legacyAmount: 1000.0, createdAt: '2026-01-01'),
  ];
  final expectedFp = restorePayloadFingerprint(rows);

  testWidgets('global confirm emits a payload-scoped global decision',
      (tester) async {
    RestorePayloadRepairDecision? decision;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      locale: const Locale('ar'),
      theme: AppTheme.light,
      home: RestorePayloadRepairView(
        rows: rows,
        onConfirm: (d) => decision = d,
        onCancel: () {},
      ),
    ));

    await tester.enterText(
        find.byKey(const Key('restore_repair_global_field')), 'EGP');
    tester.testTextInput.hide();
    await tester.ensureVisible(find.byKey(const Key('restore_repair_confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore_repair_confirm')));
    await tester.pump();

    expect(decision, isNotNull);
    expect(decision!.mode, PlanningRepairMode.global);
    expect(decision!.globalCurrency, 'EGP');
    expect(decision!.payloadFingerprint, expectedFp); // scoped to the payload
    expect(decision!.currencyForId('b1'), 'EGP');
  });

  testWidgets('an unsupported currency is rejected, not emitted',
      (tester) async {
    var confirmed = false;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      locale: const Locale('ar'),
      theme: AppTheme.light,
      home: RestorePayloadRepairView(
        rows: rows,
        onConfirm: (_) => confirmed = true,
        onCancel: () {},
      ),
    ));
    await tester.enterText(
        find.byKey(const Key('restore_repair_global_field')), 'ZZZ');
    tester.testTextInput.hide();
    await tester.ensureVisible(find.byKey(const Key('restore_repair_confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore_repair_confirm')));
    await tester.pump();
    expect(confirmed, isFalse);
    expect(find.text('رمز عملة غير مدعوم'), findsOneWidget);
  });

  testWidgets('cancel aborts (caller leaves the DB untouched)', (tester) async {
    var cancelled = false;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      locale: const Locale('ar'),
      theme: AppTheme.light,
      home: RestorePayloadRepairView(
        rows: rows,
        onConfirm: (_) {},
        onCancel: () => cancelled = true,
      ),
    ));
    await tester.ensureVisible(find.byKey(const Key('restore_repair_cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore_repair_cancel')));
    await tester.pump();
    expect(cancelled, isTrue);
  });

  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('compact repair keeps error, per-row drafts and keyboard controls reachable $language dark=$dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          final loader = FontLoader('Vazirmatn');
          for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
            loader.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
          }
          await loader.load();
        });
        final decisions = <RestorePayloadRepairDecision>[];
        var cancellations = 0;
        await tester.pumpWidget(MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.25)),
            child: child!),
          home: RestorePayloadRepairView(rows: rows,
            onConfirm: decisions.add, onCancel: () => cancellations++),
        ));
        await tester.pumpAndSettle();
        final l10n = AppL10n.of(tester.element(find.byType(RestorePayloadRepairView)));
        expect(find.byType(QirshIllustration), findsOneWidget);
        expect(find.text(l10n.rprIntro), findsOneWidget);
        final global = find.byKey(const Key('restore_repair_global_field'));
        await tester.ensureVisible(global);
        await tester.enterText(global, 'ZZZ');
        tester.testTextInput.hide();
        final confirm = find.byKey(const Key('restore_repair_confirm'));
        await tester.ensureVisible(confirm);
        await tester.pumpAndSettle();
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(decisions, isEmpty);
        expect(find.byKey(const Key('restore_repair_error')), findsOneWidget);
        expect(find.descendant(of: find.byKey(const Key('restore_repair_error')),
            matching: find.text(l10n.rprUnsupportedCode)), findsOneWidget);
        expect(tester.widget<AppCard>(find.byKey(const Key('restore_repair_error'))).variant,
            AppCardVariant.danger);
        final perItem = find.text(l10n.rprPerItem);
        await tester.ensureVisible(perItem);
        await tester.pumpAndSettle();
        await tester.tap(perItem);
        await tester.pumpAndSettle();
        expect(find.text(l10n.rprGoal), findsOneWidget);
        expect(find.text(l10n.rprBudget), findsOneWidget);
        expect(find.text(l10n.rprLegacyAmount('100.0')), findsOneWidget);
        expect(find.text(l10n.rprLegacyAmount('1000.0')), findsOneWidget);
        final budget = find.byKey(const Key('restore_repair_row_b1'));
        final goal = find.byKey(const Key('restore_repair_row_g1'));
        await tester.ensureVisible(budget);
        await tester.enterText(budget, ' egp ');
        await tester.ensureVisible(goal);
        await tester.enterText(goal, 'kwd');
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pumpAndSettle();
        await tester.ensureVisible(goal);
        await tester.pumpAndSettle();
        expect(tester.getBottomRight(goal).dy, lessThanOrEqualTo(407));
        expect(tester.widget<TextField>(goal).textDirection, TextDirection.ltr);
        expect(tester.widget<TextField>(goal).controller!.text, 'kwd',
            reason: 'the visible draft must retain the actual entered text when the keyboard inset changes');
        await tester.ensureVisible(budget);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(budget).controller!.text, ' egp ');
        await tester.ensureVisible(confirm);
        await tester.pumpAndSettle();
        expect(confirm.hitTestable(), findsOneWidget);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(decisions, hasLength(1));
        expect(decisions.single.payloadFingerprint, expectedFp);
        expect(decisions.single.mode, PlanningRepairMode.perRow);
        expect(decisions.single.globalCurrency, isNull);
        expect(decisions.single.perRowCurrency, {'b1': 'EGP', 'g1': 'KWD'});
        final cancel = find.byKey(const Key('restore_repair_cancel'));
        await tester.ensureVisible(cancel);
        await tester.pumpAndSettle();
        expect(cancel.hitTestable(), findsOneWidget);
        await tester.tap(cancel);
        expect(cancellations, 1);
        expect(decisions, hasLength(1));
        expect(tester.takeException(), isNull);
        tester.testTextInput.hide();
        tester.view.viewInsets = const FakeViewPadding();
      });
    }
  }
}
