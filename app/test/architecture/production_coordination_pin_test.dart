import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Astra R45 R8 — production construction/open/publication of a local-read scope
// requires the coordinator and an exact exclusion-backed reservation. The only
// uncoordinated shapes are explicit `...UncoordinatedForTesting` fixture APIs,
// and nothing under `lib/` may call them.

List<File> _dartFiles(String root) => [
      for (final e in Directory(root).listSync(recursive: true))
        if (e is File && e.path.endsWith('.dart')) e,
    ];

String _read(String path) => File(path).readAsStringSync();

void main() {
  // name -> the single library file allowed to DECLARE it.
  const testingApis = <String, String>{
    'openReadOnlyReplicaUncoordinatedForTesting':
        'lib/data/db/replica_store.dart',
    'restoreUncoordinatedForTesting':
        'lib/core/session/local_read_authority.dart',
    'uncoordinatedForTesting': 'lib/core/session/account_scope.dart',
    'configureUncoordinatedForTesting': 'lib/core/session/app_session.dart',
  };

  group('uncoordinated fixtures are testing-only', () {
    test('every testing API is declared @visibleForTesting in its one file',
        () {
      testingApis.forEach((name, file) {
        final lines = _read(file).split('\n');
        final declarations = [
          for (var i = 0; i < lines.length; i++)
            if (lines[i].contains(name) &&
                !lines[i].trimLeft().startsWith('//') &&
                RegExp('$name\\s*[({]|\\.$name\\s*\\(').hasMatch(lines[i]) &&
                !lines[i].contains('=>') &&
                !lines[i].contains(';'))
              i,
        ];
        expect(declarations, isNotEmpty, reason: '$name declared in $file');
        for (final i in declarations) {
          final above = lines.sublist((i - 3).clamp(0, i), i).join('\n');
          expect(above, contains('@visibleForTesting'),
              reason: '$name at $file:${i + 1}');
        }
      });
    });

    test('no code under lib/ calls an uncoordinated testing API', () {
      final offenders = <String>[];
      for (final file in _dartFiles('lib')) {
        final lines = _read(file.path).split('\n');
        for (var i = 0; i < lines.length; i++) {
          final trimmed = lines[i].trimLeft();
          if (trimmed.startsWith('//')) continue;
          for (final name in testingApis.keys) {
            if (!lines[i].contains(name)) continue;
            // A declaration sits in its one defining file directly under a
            // `@visibleForTesting` annotation; every other occurrence is a use.
            final above = lines.sublist((i - 3).clamp(0, i), i).join('\n');
            final isDeclaration = file.path == testingApis[name] &&
                above.contains('@visibleForTesting');
            if (!isDeclaration) offenders.add('${file.path}:${i + 1}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'production code must not reach an uncoordinated API');
    });
  });

  group('production signatures require the coordinator and the reservation',
      () {
    test('AccountScopeHost requires its coordinator', () {
      final src = _read('lib/core/session/account_scope.dart');
      expect(src, contains('required DatabaseAccessBroker coordinator,'));
      expect(src, isNot(contains('DatabaseAccessBroker? coordinator')));
    });

    test('configureDatabaseCoordinator takes a non-null coordinator', () {
      final src = _read('lib/core/session/app_session.dart');
      expect(
          src,
          contains('void configureDatabaseCoordinator(DatabaseAccessBroker '
              'coordinator)'));
      expect(
          src,
          isNot(
              contains('configureDatabaseCoordinator(DatabaseAccessBroker?')));
    });

    test('restore and openReadOnlyReplica require both exclusion callbacks',
        () {
      for (final file in [
        'lib/core/session/local_read_authority.dart',
        'lib/data/db/replica_store.dart',
      ]) {
        final src = _read(file);
        expect(
            src,
            contains(
                'required DatabaseOpenReservation Function(String uid) reserve,'),
            reason: file);
        expect(
            src,
            contains(
                'required void Function(ReplicaLocation location) verifyExclusion,'),
            reason: file);
      }
    });

    test(
        'publication reads the reservation the replica carries and checks '
        'coordinator, kind, uid, database, currency and a tracked open handle',
        () {
      final src = _read('lib/core/session/account_scope.dart');
      final block =
          src.substring(src.indexOf('Future<AccountScope> restoreLocalRead('));
      for (final needle in [
        'replica.reservation',
        'DatabaseReservationKind.localReadCandidate',
        'reservation.isOwnedBy(coordinator)',
        'reservation.uid == replica.uid',
        'reservation.ownsDatabase(db)',
        'reservation.isCurrent',
        '!handle.isClosed',
      ]) {
        expect(block, contains(needle), reason: needle);
      }
    });
  });

  group('production call sites are restricted', () {
    List<String> callers(Pattern pattern) => [
          for (final file in _dartFiles('lib'))
            if (RegExp(pattern.toString())
                .hasMatch(_read(file.path).replaceAll(RegExp(r'//.*'), '')))
              file.path,
        ]..sort();

    test(
        'only bootstrap constructs the production host and configures the '
        'coordinator', () {
      // account_scope.dart itself only declares the constructor.
      expect(
          callers(r'(?<![A-Za-z.])AccountScopeHost\(')
              .where((f) => f != 'lib/core/session/account_scope.dart'),
          ['lib/core/startup/bootstrap_runner.dart']);
      expect(callers(r'\.configureDatabaseCoordinator\('),
          ['lib/core/startup/bootstrap_runner.dart']);
    });

    test(
        'only the authority opens a read-only replica and only the session '
        'restores through the authority', () {
      expect(callers(r'\.openReadOnlyReplica\('),
          ['lib/core/session/local_read_authority.dart']);
      expect(callers(r'_localRead!?\.restore\(|auth\.restore\('),
          ['lib/core/session/app_session.dart']);
    });
  });
}
