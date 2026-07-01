import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/encrypted_backup_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('maps missing storage bucket into an actionable backup error', () {
    const error = supabase.StorageException(
      'Bucket not found',
      statusCode: '404',
      error: 'Bucket not found',
    );

    final message = backupStorageExceptionMessage(error);

    expect(message, contains('backups'));
    expect(message, contains('Storage bucket'));
  });

  test('Supabase migration creates private backups bucket and RLS policies',
      () {
    final sql = File('../supabase/migrations/0010_backups_bucket.sql')
        .readAsStringSync();

    expect(sql, contains("insert into storage.buckets"));
    expect(sql, contains("values ('backups', 'backups', false)"));
    expect(sql, contains("bucket_id = 'backups'"));
    expect(sql, contains("storage.foldername(name)"));
    expect(sql, contains("auth.uid()::text"));
  });
}
