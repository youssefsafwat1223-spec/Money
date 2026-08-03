import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/sync/conflict_policy.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/features/planning_sync/planning_conflicts_sheet.dart';

class _FakeResolver implements UniversalConflictResolver {
  final keepLocal = <String>[];
  final keepRemote = <String>[];

  @override
  Future<List<SyncConflict>> listConflicts() async => const [];
  @override
  Future<void> resolveKeepLocal(String entityType, String localId) async =>
      keepLocal.add('$entityType/$localId');
  @override
  Future<void> resolveKeepRemote(String entityType, String localId) async =>
      keepRemote.add('$entityType/$localId');
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  const conflict = SyncConflict(
    entityType: ConflictEntities.goal,
    localId: 'g1',
    label: 'Travel',
  );

  Future<_FakeResolver> pump(WidgetTester tester) async {
    final fake = _FakeResolver();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        conflictsProvider.overrideWith((ref) async => [conflict]),
        conflictResolverProvider.overrideWithValue(fake),
      ],
      child: const MaterialApp(
        home: Scaffold(body: PlanningConflictsSheet()),
      ),
    ));
    await tester.pumpAndSettle();
    return fake;
  }

  testWidgets('lists the conflict with keep-mine / keep-theirs actions',
      (tester) async {
    await pump(tester);
    expect(find.text('Travel'), findsOneWidget);
    expect(find.text('احتفظ بنسختي'), findsOneWidget);
    expect(find.text('نسخة الجهاز الآخر'), findsOneWidget);
  });

  testWidgets('keep-mine calls resolveKeepLocal for the conflict',
      (tester) async {
    final fake = await pump(tester);
    await tester.tap(find.text('احتفظ بنسختي'));
    await tester.pumpAndSettle();
    expect(fake.keepLocal, ['${ConflictEntities.goal}/g1']);
    expect(fake.keepRemote, isEmpty);
  });

  testWidgets('keep-theirs calls resolveKeepRemote for the conflict',
      (tester) async {
    final fake = await pump(tester);
    await tester.tap(find.text('نسخة الجهاز الآخر'));
    await tester.pumpAndSettle();
    expect(fake.keepRemote, ['${ConflictEntities.goal}/g1']);
    expect(fake.keepLocal, isEmpty);
  });
}
