import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/planning_restore_preflight.dart';
import 'package:money_companion/data/db/planning_currency_repair.dart'
    show PlanningRepairMode;
import 'package:money_companion/features/backup/restore_payload_repair_view.dart';
import 'package:money_companion/core/theme/app_theme.dart';

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
      theme: AppTheme.light,
      home: RestorePayloadRepairView(
        rows: rows,
        onConfirm: (d) => decision = d,
        onCancel: () {},
      ),
    ));

    await tester.enterText(
        find.byKey(const Key('restore_repair_global_field')), 'EGP');
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
      theme: AppTheme.light,
      home: RestorePayloadRepairView(
        rows: rows,
        onConfirm: (_) => confirmed = true,
        onCancel: () {},
      ),
    ));
    await tester.enterText(
        find.byKey(const Key('restore_repair_global_field')), 'ZZZ');
    await tester.tap(find.byKey(const Key('restore_repair_confirm')));
    await tester.pump();
    expect(confirmed, isFalse);
    expect(find.text('رمز عملة غير مدعوم'), findsOneWidget);
  });

  testWidgets('cancel aborts (caller leaves the DB untouched)', (tester) async {
    var cancelled = false;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: RestorePayloadRepairView(
        rows: rows,
        onConfirm: (_) {},
        onCancel: () => cancelled = true,
      ),
    ));
    await tester.tap(find.byKey(const Key('restore_repair_cancel')));
    await tester.pump();
    expect(cancelled, isTrue);
  });
}
