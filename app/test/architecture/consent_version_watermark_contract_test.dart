import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The consent version watermark is allocation metadata. These pins keep it that
// way: the planning pull never imports consent, the backup restore never touches
// the watermark table, and the reservation changes no consent state.

String _read(String path) => File(path).readAsStringSync();

String _body(String source, String signature) {
  final at = source.indexOf(signature);
  expect(at, greaterThan(-1), reason: '$signature not found');
  final open = source.indexOf('{', at + signature.length);
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) return source.substring(open, i + 1);
  }
  fail('unbalanced braces after $signature');
}

void main() {
  test('the planning pull never writes a consent column', () {
    final body = _body(
        _read('lib/features/planning_sync/services/planning_pull_service.dart'),
        'Future<void> _updateSettings(');
    // Strip SQL comments, then no consent assignment may remain.
    final sql = body.replaceAll(RegExp(r'--[^\n]*'), '');
    expect(
        RegExp(r'(cloud_consent|ai_consent|cloud_processing|consent_version)\w*\s*=')
            .hasMatch(sql),
        isFalse);
  });

  test('the backup restore keeps the device watermark', () {
    expect(_read('lib/core/backup/restore_backup_usecase.dart'),
        isNot(contains('consent_version_watermark')));
  });

  test('the reservation writes only the watermark table', () {
    final source =
        _read('lib/data/repositories/drift_user_settings_repository.dart');
    final start = source.indexOf('Future<int> reserveConsentVersion(');
    final end = source.indexOf('_saveWithinTransaction(', start);
    final body = source.substring(start, end);
    expect(body, isNot(contains('UPDATE user_settings')));
    expect(body, isNot(contains('enqueue')));
    expect(body, contains('consent_version_watermark'));
  });
}
