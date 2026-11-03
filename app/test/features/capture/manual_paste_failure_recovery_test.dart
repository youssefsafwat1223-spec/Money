import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/features/capture/manual_paste_screen.dart';
import 'package:money_companion/features/capture/manual_paste_splitter.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'manual-paste-failure-memory-only';
  @override
  Future<String?> readStoredKey() async => 'manual-paste-failure-memory-only';
}

/// This seam never enters the ingest implementation, constructs authority,
/// writes data or returns a completed financial result. It only holds/fails.
class _FailingIngest implements IngestCapturedMessageUseCase {
  Completer<CapturedMessageResult>? pending;
  final messages = <CapturedMessage>[];

  @override
  Future<CapturedMessageResult> fromCapturedMessage(CapturedMessage message, {
    bool onDeviceOnly = false,
    CaptureCommit? capture,
    bool forceLocalAutoConfirm = false,
  }) {
    messages.add(message);
    if (onDeviceOnly || capture != null || forceLocalAutoConfirm) {
      throw StateError('unexpected_capture_authority_or_mode');
    }
    return pending?.future ?? Future<CapturedMessageResult>.error(
        StateError('private-synthetic-ingest-storage-detail'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Map<String, Object>> _snapshot(AppDatabase db) async {
  final tables = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").get();
  return {
    for (final row in tables)
      row.read<String>('name'): (await db.customSelect(
          'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid').get())
          .map((value) => value.data).toList(),
  };
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(),
        keyStore: _Keys(), initialLanguage: 'en');
  });
  tearDown(() async => db.close());

  for (final batch in [false, true]) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('manual paste ${batch ? 'batch' : 'single'} failure recovers $language dark$dark', (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          const first = 'Your Debit Card purchase EGP 250.00 at QA SHOP on 01/11';
          const second = 'Your Debit Card purchase EGP 350.00 at QA STORE on 01/11';
          final originalText = batch ? '$first\n\n$second' : first;
          expect(ManualPasteSplitter.split(originalText), hasLength(batch ? 2 : 1));
          final ingest = _FailingIngest();
          final gate = ingest.pending = Completer<CapturedMessageResult>();
          final before = await _snapshot(db);
          var addedCallbacks = 0;
          await tester.pumpWidget(ProviderScope(overrides: [
            appDatabaseProvider.overrideWithValue(db),
            ingestCapturedMessageUseCaseProvider.overrideWithValue(ingest),
          ], child: MaterialApp(
            theme: dark ? AppTheme.dark : AppTheme.light,
            locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            home: ManualPasteScreen(onTransactionAdded: (_) => addedCallbacks++),
          )));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), originalText);
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
          final l10n = AppL10n.of(tester.element(find.byType(ManualPasteScreen)));
          final analyze = find.widgetWithText(FilledButton, l10n.pasteAnalyse);
          await tester.ensureVisible(analyze);
          await tester.pumpAndSettle();
          final analyzePosition = tester.getCenter(analyze);
          await tester.tap(analyze);
          await tester.pump(const Duration(milliseconds: 200));
          expect(ingest.messages, hasLength(1));
          expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
          expect(find.byType(CircularProgressIndicator), findsWidgets);
          await tester.tapAt(analyzePosition);
          await tester.pump(const Duration(milliseconds: 80));
          expect(ingest.messages, hasLength(1));
          gate.completeError(StateError('private-synthetic-ingest-storage-detail'));
          ingest.pending = null;
          await tester.pump(const Duration(milliseconds: 300));
          final uncaught = tester.takeException();
          final feedback = find.text(l10n.txnError).evaluate().isNotEmpty;
          expect(find.textContaining('private-synthetic'), findsNothing);
          final enabled = tester.widget<FilledButton>(find.byType(FilledButton)).onPressed != null;
          final retainedText = tester.widget<TextField>(find.byType(TextField)).controller!.text;
          if (enabled) {
            await tester.ensureVisible(find.widgetWithText(FilledButton, l10n.pasteAnalyse));
            await tester.pump();
            await tester.tap(find.widgetWithText(FilledButton, l10n.pasteAnalyse));
            await tester.pump(const Duration(milliseconds: 300));
          }
          final retryUncaught = tester.takeException();
          await tester.pump(const Duration(seconds: 7));
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          expect(uncaught, isNull);
          expect(retryUncaught, isNull);
          expect(feedback, isTrue);
          expect(enabled, isTrue);
          expect(retainedText, originalText);
          expect(ingest.messages, hasLength(2), reason: 'Failure permits one actual retry; a batch stops before ingesting its second message.');
          for (final message in ingest.messages) {
            expect(message.text, first);
            expect(message.source, CapturedMessageSource.manualPaste);
            expect(message.senderId, isNull);
          }
          expect(addedCallbacks, 0);
          expect(await _snapshot(db), before);
        });
      }
    }
  }
}
