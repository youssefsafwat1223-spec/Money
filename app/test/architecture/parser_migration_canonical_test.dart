import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Migration 0099 must CONSUME the generated canonical rule SQL, not restate it.
///
/// 0091 widened the amount quantifier in the database while the bundled asset
/// kept the old shape, and nothing noticed for months, because each copy was
/// maintained by hand. One canonical source now projects into two generated
/// artifacts, and this pins the third link: the migration body must be the
/// generated SQL verbatim, so a regex can never be retyped into the database.
void main() {
  final generated =
      File('../supabase/catalog/generated/parser_rules.sql').readAsStringSync();
  final migration = File(
    '../supabase/migrations/0099_parser_safety_rule_scoped_evidence.sql',
  ).readAsStringSync();

  group('0099 consumes the generated canonical rule SQL', () {
    test('the generated file exists and is non-trivial', () {
      expect(generated, contains('GENERATED — DO NOT EDIT'));
      expect(generated, contains('UPDATE public.sms_parsers SET'));
    });

    test('every generated statement appears in the migration verbatim', () {
      // Verbatim, not "contains something similar": a hand-edited copy is
      // exactly the failure mode this guard exists to prevent.
      expect(migration, contains(generated),
          reason: 'regenerate with tools/gen_catalog_assets.py and re-embed');
    });

    test('all twelve stable parser ids are covered', () {
      final ids = RegExp(r'10000000-0000-4000-8000-[0-9]{12}')
          .allMatches(generated)
          .map((m) => m.group(0))
          .toSet();
      expect(ids.length, 12, reason: 'a rule was added or dropped silently');
      for (final id in ids) {
        expect(migration, contains(id));
      }
    });

    test('the SNB rule carries the bilingual currency-adjacency grammar', () {
      expect(migration, contains('(?<='), reason: 'currency-before assertion');
      expect(migration, contains('(?='), reason: 'currency-after assertion');
    });

    test('the migration promotes nothing', () {
      // Promotion is the Parser Lab's job and requires evidence this migration
      // does not carry. The postcondition READS validation_status to assert
      // exactly that, so this distinguishes reads from writes rather than
      // banning the word.
      const evidenceColumns = [
        'validation_status',
        'validated_at',
        'golden_test_count',
      ];
      for (final line in migration.split('\n')) {
        final t = line.trim();
        if (t.startsWith('--')) continue;
        if (!evidenceColumns.any(t.contains)) continue;
        // A read is fine: SELECT ... , WHERE ..., or a RAISE message.
        final isRead = t.startsWith('SELECT') ||
            t.startsWith('WHERE') ||
            t.startsWith('IF ') ||
            t.startsWith('RAISE');
        expect(isRead, isTrue,
            reason: '0099 appears to WRITE validation evidence: $t');
      }
    });

    test('it has a rollback, and the rollback warns about the SNB revert', () {
      final rollback = File(
        '../supabase/rollback/'
        '0099_parser_safety_rule_scoped_evidence_rollback.sql',
      );
      expect(rollback.existsSync(), isTrue);
      expect(rollback.readAsStringSync(), contains('WRONG-MONEY'),
          reason: 'reverting the SNB rule restores a reproduced defect');
    });
  });

  group('deferred telemetry stays deferred and uncollided', () {
    test('it is numbered 0100 and lives outside migrations/', () {
      expect(
        File('../supabase/deferred/0100_record_metric_ad_keys.sql').existsSync(),
        isTrue,
      );
      final active = Directory('../supabase/migrations')
          .listSync()
          .map((e) => e.path.split('/').last)
          .toList();
      expect(active.any((f) => f.contains('record_metric')), isFalse,
          reason: 'the telemetry migration must not become active');
      expect(active.any((f) => f.startsWith('0100')), isFalse,
          reason: 'no active migration may collide with the deferred number');
    });

    test('0099 carries none of the deferred telemetry content', () {
      expect(migration.contains('record_metric'), isFalse);
      expect(migration.contains('report_export'), isFalse);
    });
  });
}
