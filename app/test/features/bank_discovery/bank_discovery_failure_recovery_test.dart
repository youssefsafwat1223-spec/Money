import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/sender_bank_mapping_entity.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';
import 'package:money_companion/features/bank_discovery/bank_discovery_confirmation_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'bank-discovery-failure-memory';
  @override
  Future<String?> readStoredKey() async => 'bank-discovery-failure-memory';
}

// Intercept before a write, never return an accepted/rejected mapping or grant.
class _FailingMappingRepository implements SenderBankMappingRepository {
  Completer<SenderBankMappingEntity>? pending;
  final attempts = <String>[];
  final ids = <String>[];
  final banks = <String?>[];
  final cooldowns = <Duration>[];
  Future<SenderBankMappingEntity> _fail(String operation, String id) {
    attempts.add(operation);
    ids.add(id);
    return pending?.future ??
        Future<SenderBankMappingEntity>.error(
            StateError('private-synthetic-bank-repository-detail'));
  }

  @override
  Future<SenderBankMappingEntity> confirm(
      {required String mappingId, String? bankKey, DateTime? now}) {
    banks.add(bankKey);
    return _fail('confirm', mappingId);
  }

  @override
  Future<SenderBankMappingEntity> reject(
      {required String mappingId, required Duration cooldown, DateTime? now}) {
    cooldowns.add(cooldown);
    return _fail('reject', mappingId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected-bank-repository-operation');
}

SenderBankMappingEntity _proposal() {
  final now = DateTime.utc(2026, 6, 16);
  return SenderBankMappingEntity(
      id: 'qa-failing-bank-proposal',
      senderId: 'QA BANK',
      normalizedSenderId: 'QA BANK',
      bankKey: 'qa_bank',
      suggestedBankName: 'QA Bank',
      suggestedCountry: 'EG',
      confidence: .97,
      reason: 'Synthetic pending proposal',
      status: SenderBankMappingStatus.pending,
      source: SenderBankMappingSource.gemini,
      firstSeenAt: now,
      lastSeenAt: now,
      createdAt: now,
      updatedAt: now,
      confirmedAt: null,
      rejectedAt: null,
      rejectionExpiresAt: null,
      syncedAt: null,
      syncStatus: SenderBankMappingSyncStatus.pending);
}

Future<Map<String, Object>> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final row in tables)
      row.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((value) => value.data)
          .toList()
  };
}

void main() {
  late AppDatabase db;
  setUp(() async => db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _Keys(),
      initialLanguage: 'en'));
  tearDown(() async => db.close());
  for (final operation in ['confirm', 'reject']) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets(
            'public bank $operation failure recovers $language dark$dark without writes',
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
          final repository = _FailingMappingRepository();
          final pending =
              repository.pending = Completer<SenderBankMappingEntity>();
          final proposal = _proposal();
          final before = await _snapshot(db);
          await tester.pumpWidget(ProviderScope(
              overrides: [
                appDatabaseProvider.overrideWithValue(db),
                senderBankMappingRepositoryProvider
                    .overrideWithValue(repository),
                senderBankMappingSyncServiceProvider.overrideWithValue(null),
              ],
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  home: Scaffold(
                      body:
                          BankDiscoveryConfirmationSheet(mapping: proposal)))));
          await tester.pumpAndSettle();
          final l10n = AppL10n.of(
              tester.element(find.byType(BankDiscoveryConfirmationSheet)));
          Finder action() => operation == 'confirm'
              ? find.widgetWithText(FilledButton, l10n.bdConfirmThis)
              : find.widgetWithText(OutlinedButton, l10n.bdNotThis);
          await tester.ensureVisible(action());
          await tester.pumpAndSettle();
          final position = tester.getCenter(action());
          await tester.tap(action());
          await tester.pump(const Duration(milliseconds: 150));
          expect(repository.attempts, [operation]);
          expect(
              tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
              isNull);
          expect(
              tester
                  .widget<OutlinedButton>(find.byType(OutlinedButton))
                  .onPressed,
              isNull);
          expect(tester.widget<TextButton>(find.byType(TextButton)).onPressed,
              isNull);
          await tester.tapAt(position);
          await tester.pump();
          expect(repository.attempts, [operation]);
          pending.completeError(
              StateError('private-synthetic-bank-repository-detail'));
          repository.pending = null;
          await tester.pump(const Duration(milliseconds: 300));
          final unhandled = tester.takeException();
          final feedback = find.text(l10n.txnError).evaluate().isNotEmpty;
          expect(find.textContaining('private-synthetic'), findsNothing);
          expect(find.byType(BankDiscoveryConfirmationSheet), findsOneWidget);
          expect(
              tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
              isNotNull);
          expect(
              tester
                  .widget<OutlinedButton>(find.byType(OutlinedButton))
                  .onPressed,
              isNotNull);
          await tester.ensureVisible(action());
          await tester.pump();
          await tester.tap(action());
          await tester.pump(const Duration(milliseconds: 300));
          final retryUnhandled = tester.takeException();
          await tester.pump(const Duration(seconds: 7));
          expect(await _snapshot(db), before);
          expect(repository.attempts, [operation, operation]);
          expect(repository.ids, [proposal.id, proposal.id]);
          if (operation == 'confirm') {
            expect(repository.banks, [proposal.bankKey, proposal.bankKey]);
          }
          if (operation == 'reject') {
            expect(repository.cooldowns,
                [const Duration(days: 30), const Duration(days: 30)]);
          }
          expect(proposal.status, SenderBankMappingStatus.pending);
          expect(unhandled, isNull);
          expect(retryUnhandled, isNull);
          expect(feedback, isTrue);
        });
      }
    }
  }
}
