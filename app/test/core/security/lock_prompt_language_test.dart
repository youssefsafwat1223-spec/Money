import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/security/lock_prompt_language.dart';

/// The keychain mirror of `user_settings.language`, and the rule that keeps it
/// honest: every path that writes the column must write the mirror too.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('the mirror', () {
    test('nothing mirrored yet reads as the app default', () async {
      // Every install upgrading into this build is in this state, and Arabic is
      // the right answer for them: before Settings → Language shipped, no user
      // could hold anything else.
      expect(await LockPromptLanguage.read(), 'ar');
    });

    test('round-trips both supported languages', () async {
      await LockPromptLanguage.set('en');
      expect(await LockPromptLanguage.read(), 'en');
      await LockPromptLanguage.set('ar');
      expect(await LockPromptLanguage.read(), 'ar');
    });

    test('an unsupported code degrades to the default, it does not throw',
        () async {
      // This value is read from inside the lock. A prompt in the wrong language
      // is a defect; an exception there is a lockout.
      await LockPromptLanguage.set('fr');
      expect(await LockPromptLanguage.read(), 'ar');
    });
  });

  test('every writer of user_settings.language mirrors it', () {
    // The mirror is only as good as its coverage. A new writer that forgets it
    // leaves the unlock prompt one launch — or permanently — behind the app.
    //
    // The three below each mirror in the same await chain as their write, so
    // the mirror is already correct when the write returns. That is the
    // property the previous, provider-driven cache did not have: it passed once
    // and failed the next run, because "when a provider runs" is not orderable
    // against the process ending.
    const writers = <String, String>{
      'lib/domain/usecases/user_settings_usecases.dart':
          'SaveLanguageUseCase — Settings → Language, the only path a user can '
              'take',
      'lib/features/planning_sync/services/planning_pull_service.dart':
          'a server row carrying a language, which is how a second device '
              'inherits a choice made on the first',
      'lib/core/backup/restore_backup_usecase.dart':
          'a backup snapshot carrying a language (mirrored post-commit, so a '
              'rolled-back restore leaves the mirror alone)',
    };
    // Files that merely READ or carry the column: entity copyWith, row
    // decoding, the DAO that defines it, and the seed INSERT (see the class
    // doc for why the seed is deliberately not a mirror site).
    const readersAndCarriers = <String>{
      'lib/domain/entities/supporting_entities.dart',
      'lib/data/repositories/drift_repository_support.dart',
      'lib/data/repositories/drift_user_settings_repository.dart',
      'lib/data/catalog/catalog_daos.dart',
      'lib/data/db/app_database.dart',
      'lib/core/backup/backup_snapshot_builder.dart',
      'lib/features/settings/settings_screen.dart',
      'lib/core/i18n/locale_provider.dart',
    };

    final missing = <String>[];
    final unexpected = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      if (readersAndCarriers.contains(file.path)) continue;
      final source = file.readAsStringSync();
      // The write shapes: `copyWith(language:` through the entity, and
      // `language = ` inside raw settings SQL.
      final writes = source.contains('copyWith(language:') ||
          RegExp(r'language = \$\{keep\(').hasMatch(source) ||
          RegExp(r"UPDATE user_settings[\s\S]{0,600}?language\s*=")
              .hasMatch(source);
      final mirrors = source.contains('LockPromptLanguage.set(');
      if (writes && !mirrors) missing.add(file.path);
      if (mirrors && !writers.containsKey(file.path)) {
        unexpected.add(file.path);
      }
    }

    expect(missing, isEmpty,
        reason: 'these write user_settings.language without mirroring it, so '
            'the unlock prompt will disagree with the app: '
            '${missing.join(", ")}. Call LockPromptLanguage.set in the same '
            'await chain as the write, then add the file here with its reason.');
    expect(unexpected, isEmpty,
        reason: 'these mirror the language but are not declared writers — '
            'either add them with a reason, or remove the mirror: '
            '${unexpected.join(", ")}');
    for (final entry in writers.entries) {
      expect(File(entry.key).existsSync(), isTrue,
          reason: '${entry.key} is declared a writer but no longer exists');
      expect(File(entry.key).readAsStringSync(),
          contains('LockPromptLanguage.set('),
          reason: '${entry.key} stopped mirroring the language (${entry.value})');
    }
  });
}
