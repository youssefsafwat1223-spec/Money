import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// MALI-069n (Batch-4 closure #4) — Contract B ENFORCEMENT (see
// docs/PROCESS_ACCESS_INVENTORY.md). Exactly one OS process (the Flutter host app)
// may open the Drift/SQLCipher database; every separate-process target (iOS Share
// extension, App Intents, Android receivers) is pure-native and stages to the App
// Group / SharedPreferences only. These source-scan tests fail the gate if a future
// change lets a separate-process target import/open the database, or adds a new
// Dart open site outside the three approved ones.

/// Repo root = two levels up from the flutter package dir (…/app).
Directory _repoRoot() {
  // Tests run with CWD = the app package directory.
  return Directory.current.parent;
}

Iterable<File> _swiftFiles(Directory d) sync* {
  if (!d.existsSync()) return;
  for (final e in d.listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.swift')) yield e;
  }
}

void main() {
  final app = Directory.current; // …/app

  test('no iOS separate-process target embeds a Flutter engine or opens SQLite',
      () {
    final ios = Directory('${app.path}/ios');
    for (final target in ['ShareBankMessage', 'BankMessageShortcuts']) {
      final targetDir = Directory('${ios.path}/$target');
      if (!targetDir.existsSync()) continue;
      for (final f in _swiftFiles(targetDir)) {
        final src = f.readAsStringSync();
        // No Flutter runtime → the sqlite3mc/Drift plugin can never load here.
        expect(src.contains('FlutterEngine'), isFalse,
            reason: '${f.path} must not run a Flutter engine');
        expect(src.contains('FlutterViewController'), isFalse,
            reason: '${f.path} must not run a Flutter engine');
        expect(src.contains('GeneratedPluginRegistrant'), isFalse,
            reason: '${f.path} must not register Flutter plugins');
        // And no direct native SQLite either.
        for (final needle in ['sqlite3', 'SQLite', 'sqlcipher', 'GRDB', 'FMDB']) {
          expect(src.contains(needle), isFalse,
              reason: '${f.path} must not open a database ($needle)');
        }
      }
    }
  });

  test('no native target references the SQLCipher database file or sqlite APIs',
      () {
    for (final platform in ['ios', 'android']) {
      final dir = Directory('${app.path}/$platform');
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync(recursive: true)) {
        if (e is! File) continue;
        if (!(e.path.endsWith('.swift') ||
            e.path.endsWith('.kt') ||
            e.path.endsWith('.java') ||
            e.path.endsWith('.m'))) {
          continue;
        }
        final src = e.readAsStringSync();
        for (final needle in ['sqlite3mc', 'money_companion.sqlite', 'sqlcipher']) {
          expect(src.contains(needle), isFalse,
              reason: '${e.path} must not touch the encrypted DB ($needle)');
        }
      }
    }
  });

  test('the Android manifest declares no separate process for any component', () {
    final manifest =
        File('${app.path}/android/app/src/main/AndroidManifest.xml');
    if (!manifest.existsSync()) return;
    final src = manifest.readAsStringSync();
    // An enabled android:process would move a component to another OS process,
    // breaking the single-process invariant. (A commented-out block is fine.)
    final activeLines = src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('<!--') && !l.contains('-->'));
    for (final line in activeLines) {
      expect(line.contains('android:process'), isFalse,
          reason: 'no component may run in a separate OS process');
    }
  });

  test('Dart opens the database in exactly the three approved sites', () {
    final lib = Directory('${app.path}/lib');
    final opens = <String>[];
    for (final e in lib.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final src = e.readAsStringSync();
      if (RegExp(r'AppDatabase\.open\(').hasMatch(src)) {
        opens.add('${e.path}: AppDatabase.open');
      }
      if (RegExp(r'AppDatabase\.openSecondary\(').hasMatch(src)) {
        opens.add('${e.path}: AppDatabase.openSecondary');
      }
    }
    // bootstrap_runner (main) + the two same-process background isolates.
    final files = opens.map((o) => o.split('/').last).toSet();
    expect(
      files,
      containsAll(<String>[
        'bootstrap_runner.dart: AppDatabase.open',
        'captured_message_processor.dart: AppDatabase.openSecondary',
        'local_notification_service.dart: AppDatabase.openSecondary',
      ]),
      reason: 'the approved open sites must all be present',
    );
    // Any NEW open site is a Contract-B regression to review.
    final approved = {
      'bootstrap_runner.dart',
      'captured_message_processor.dart',
      'local_notification_service.dart',
      'app_database.dart', // the definitions themselves
    };
    for (final o in opens) {
      final base = o.split(': ').first.split('/').last;
      expect(approved.contains(base), isTrue,
          reason: 'unexpected DB open site: $o (Contract-B review required)');
    }
  });

  test('repo-root sanity: the app package resolves', () {
    expect(_repoRoot().existsSync(), isTrue);
  });
}
