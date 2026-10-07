import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/sync/conflict_fields.dart';
import 'package:money_companion/core/sync/conflict_policy.dart';
import 'package:money_companion/core/sync/sync_conflict_store.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/features/planning_sync/planning_conflicts_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _FakeResolver implements UniversalConflictResolver {
  final keepLocal = <String>[];
  final keepRemote = <String>[];

  @override
  Future<List<SyncConflict>> listConflicts() async => const [];
  @override
  Future<void> resolveKeepLocal(String entityType, String localId) async =>
      keepLocal.add('$entityType/$localId');
  @override
  Future<bool> resolveKeepRemote(String entityType, String localId) async {
    keepRemote.add('$entityType/$localId');
    return true;
  }
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  const conflict = SyncConflict(
    entityType: ConflictEntities.goal,
    localId: 'g1',
    label: 'Travel',
  );

  Future<_FakeResolver> pump(WidgetTester tester,
      {SyncConflict c = conflict, Locale locale = const Locale('ar')}) async {
    final fake = _FakeResolver();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        conflictsProvider.overrideWith((ref) async => [c]),
        conflictResolverProvider.overrideWithValue(fake),
      ],
      child: MaterialApp(
        // The sheet reads its copy from the ARB now.
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        locale: locale,
        home: const Scaffold(body: PlanningConflictsSheet()),
      ),
    ));
    await tester.pumpAndSettle();
    return fake;
  }

  testWidgets('lists the conflict with Keep mine / Keep cloud actions',
      (tester) async {
    await pump(tester);
    expect(find.text('Travel'), findsOneWidget);
    expect(find.text('الإبقاء على نسختي'), findsOneWidget);
    expect(find.text('الإبقاء على نسخة السحابة'), findsOneWidget);
  });

  testWidgets('keep-mine calls resolveKeepLocal for the conflict',
      (tester) async {
    final fake = await pump(tester);
    await tester.tap(find.text('الإبقاء على نسختي'));
    await tester.pumpAndSettle();
    expect(fake.keepLocal, ['${ConflictEntities.goal}/g1']);
    expect(fake.keepRemote, isEmpty);
  });

  testWidgets('keep-cloud calls resolveKeepRemote for the conflict',
      (tester) async {
    final fake = await pump(tester);
    await tester.tap(find.text('الإبقاء على نسخة السحابة'));
    await tester.pumpAndSettle();
    expect(fake.keepRemote, ['${ConflictEntities.goal}/g1']);
    expect(fake.keepLocal, isEmpty);
  });

  // SYNC-Q5: the screen shows the meaningful field differences.
  const withFields = SyncConflict(
    entityType: ConflictEntities.transaction,
    localId: 't1',
    label: 'Cafe',
    kind: SyncConflictKind.update,
    fields: [
      ConflictFieldDiff(ConflictFieldKey.amount, '100', '250'),
      ConflictFieldDiff(ConflictFieldKey.note, null, 'lunch'),
    ],
  );

  testWidgets('field differences (en): each differing field, mine vs cloud',
      (tester) async {
    await pump(tester, c: withFields, locale: const Locale('en'));
    expect(find.text('Amount'), findsOneWidget);
    expect(find.text('This device: 100'), findsOneWidget);
    expect(find.text('Cloud: 250'), findsOneWidget);
    expect(find.text('Note'), findsOneWidget);
    expect(find.text('This device: Not set'), findsOneWidget);
    expect(find.text('Cloud: lunch'), findsOneWidget);
    expect(find.text('Keep mine'), findsOneWidget);
    expect(find.text('Keep cloud version'), findsOneWidget);
  });

  testWidgets('field differences (ar) render the same rows', (tester) async {
    await pump(tester, c: withFields);
    expect(find.text('المبلغ'), findsOneWidget);
    expect(find.text('هذا الجهاز: 100'), findsOneWidget);
    expect(find.text('السحابة: 250'), findsOneWidget);
  });

  testWidgets('cloud tombstone: a transaction keeps mine as a NEW copy '
      '(a tombstone is never un-deleted)',
      (tester) async {
    await pump(
        tester,
        c: const SyncConflict(
          entityType: ConflictEntities.transaction,
          localId: 't1',
          label: 'Cafe',
          kind: SyncConflictKind.tombstone,
        ),
        locale: const Locale('en'));
    expect(find.text('Deleted in the cloud'), findsOneWidget);
    expect(find.text('Keep mine as a new copy'), findsOneWidget);
  });

  testWidgets('cloud tombstone on a non-transaction: Keep cloud only',
      (tester) async {
    await pump(
        tester,
        c: const SyncConflict(
          entityType: ConflictEntities.goal,
          localId: 'g1',
          label: 'Travel',
          kind: SyncConflictKind.tombstone,
          canKeepMine: false,
        ),
        locale: const Locale('en'));
    expect(find.text('Deleted in the cloud'), findsOneWidget);
    expect(find.text('Keep mine'), findsNothing);
    expect(find.text('Keep mine as a new copy'), findsNothing);
    expect(find.text('Keep cloud version'), findsOneWidget);
  });
}
