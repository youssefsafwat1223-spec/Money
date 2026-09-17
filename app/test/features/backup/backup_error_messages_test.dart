import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/restore_controller.dart';
import 'package:money_companion/features/backup/backup_error_messages.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// A restore failure is read at the worst moment a person using this app will
/// have: their data did not come back. Leaving that message in one language is
/// the same defect as an untranslated button, with higher stakes.
void main() {
  Future<Map<BackupError, String>> renderedIn(
      WidgetTester tester, String lang) async {
    late Map<BackupError, String> out;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      locale: Locale(lang),
      home: Builder(builder: (context) {
        out = {
          for (final code in BackupError.values)
            // A placeholder-bearing message must still render with an arg.
            code: backupErrorMessage(context, code, args: const ['transactions']),
        };
        return const SizedBox();
      }),
    ));
    return out;
  }

  testWidgets('every backup error code renders in both languages',
      (tester) async {
    final arabicScript = RegExp(r'[؀-ۿ]');
    final ar = await renderedIn(tester, 'ar');
    final en = await renderedIn(tester, 'en');

    for (final code in BackupError.values) {
      expect(ar[code]!.trim(), isNotEmpty, reason: '$code is empty in Arabic');
      expect(en[code]!.trim(), isNotEmpty, reason: '$code is empty in English');
      // `Supabase`, `backups` and a table name are Latin identifiers, so this
      // only catches Arabic copy left in the English rendering.
      expect(arabicScript.hasMatch(en[code]!), isFalse,
          reason: '$code still reads Arabic in English: ${en[code]}');
      expect(ar[code], isNot(en[code]),
          reason: '$code is identical in both languages');
    }
  });

  testWidgets('a code-less exception falls back to its own message',
      (tester) async {
    late String rendered;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      locale: const Locale('en'),
      home: Builder(builder: (context) {
        rendered = backupExceptionMessage(
            context, const BackupException('raw message'));
        return const SizedBox();
      }),
    ));
    // Deliberate: a throw site not yet given a code must still show SOMETHING.
    expect(rendered, 'raw message');
  });

  testWidgets('a restore state renders its code, not its Arabic message',
      (tester) async {
    late String? rendered;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      locale: const Locale('en'),
      home: Builder(builder: (context) {
        rendered = restoreStateMessage(
          context,
          const RestoreUiState(
            phase: RestoreUiPhase.failedWithoutChanges,
            message: 'تعذّرت الاستعادة ولم تتغيّر بياناتك الحالية.',
            code: BackupError.restoreFailedNoChanges,
          ),
        );
        return const SizedBox();
      }),
    ));
    expect(rendered, 'The restore failed, and your current data is unchanged.');
  });

  test('every bke* key exists in both ARB files', () {
    final ar = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
        as Map<String, dynamic>;
    final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;
    final keys = ar.keys.where((k) => k.startsWith('bke')).toSet();
    expect(keys.length, greaterThanOrEqualTo(BackupError.values.length));
    for (final k in keys) {
      expect(en[k], isA<String>(), reason: '$k is missing from the English ARB');
    }
  });
}
