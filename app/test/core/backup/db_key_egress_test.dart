import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/encrypted_backup_service.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/core/data_portability/drift_financial_exporter.dart';
import 'package:money_companion/core/observability/telemetry_sanitizer.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

// MALI-058n (closure) — a unique key canary must never egress through the remote
// upload metadata, any export surface, or logs/telemetry.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

const _canary = 'KEY-CANARY-EGRESS-8a17';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> open() =>
      AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

  // ── Remote backup upload ──────────────────────────────────────────────────
  test('remote-backup upload metadata has a fixed schema with no key canary',
      () {
    final md = EncryptedBackupService.uploadMetadata(
      userId: 'user-1',
      path: 'user-1/backup.enc',
      blobVersion: 3,
      sizeBytes: 4096,
      updatedAtIso: '2026-01-01T00:00:00.000Z',
    );
    // Only these fields are ever uploaded as metadata — none derived from
    // user_settings or a key.
    expect(md.keys.toSet(),
        {'user_id', 'blob_path', 'blob_version', 'size_bytes', 'updated_at'});
    expect(jsonEncode(md).contains(_canary), isFalse);
    // The object path is derived from the user id, never settings/key material.
    expect(md['blob_path'], 'user-1/backup.enc');
  });

  // ── Export surfaces ───────────────────────────────────────────────────────
  test('CSV and full-data package exports never contain the key field/canary',
      () async {
    final db = await open();
    addTearDown(db.close);
    await db.customStatement(
      "UPDATE user_settings SET db_encryption_key_ref = '$_canary';",
    );
    final exporter = DriftFinancialExporter(db);
    final csv = await exporter.exportTransactionsCsv();
    final pkg = await exporter.exportFinancialPackage();
    for (final bytes in [csv.bytes, pkg.bytes]) {
      final text = utf8.decode(bytes, allowMalformed: true);
      expect(text.contains(_canary), isFalse);
      expect(text.contains('db_encryption_key_ref'), isFalse);
    }
  });

  // ── Logs / telemetry ──────────────────────────────────────────────────────
  test('a restore fail-closed error names the table but never the field VALUE',
      () async {
    final src = await open();
    addTearDown(src.close);
    final snapshot = await BackupSnapshotBuilder(src).build();
    (snapshot['tables']['user_settings'] as List)
        .cast<Map<String, dynamic>>()
        .first['leaked_secret_key'] = _canary;

    final dst = await open();
    addTearDown(dst.close);
    Object? thrown;
    try {
      await RestoreBackupUseCase(dst).call(snapshot);
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isA<BackupException>());
    // The user-visible error must not echo the sensitive field's value.
    expect(thrown.toString().contains(_canary), isFalse);
  });

  test('telemetry sanitization drops a key canary placed in an exception', () {
    final event = SentryEvent(
      exceptions: <SentryException>[
        SentryException(
          type: 'StateError',
          value: 'db key leaked: $_canary',
          throwable: StateError('db key leaked: $_canary'),
        ),
      ],
      message: SentryMessage('failure carrying $_canary'),
    );
    final sanitized = TelemetrySanitizer.sanitizeEvent(event);
    final wire = jsonEncode(sanitized.toJson());
    expect(wire.contains(_canary), isFalse);
  });
}
