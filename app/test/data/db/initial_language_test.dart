import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';

class _Key implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory';
  @override
  Future<String?> readStoredKey() async => 'memory';
}

void main() {
  test('a new settings row defaults to English', () async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _Key());
    addTearDown(db.close);
    expect(
        (await DriftUserSettingsRepository(db).getSettings()).language, 'en');
  });

  test(
      'explicit onboarding language carries into a fresh account and survives reopening',
      () async {
    final dir = await Directory.systemTemp.createTemp('qirsh-language-');
    final file = File('${dir.path}/replica.sqlite');
    AppDatabase? db;
    try {
      db = await AppDatabase.open(
          executor: NativeDatabase(file),
          keyStore: _Key(),
          initialLanguage: 'ar');
      expect(
          (await DriftUserSettingsRepository(db).getSettings()).language, 'ar');
      await db.close();
      db = await AppDatabase.open(
          executor: NativeDatabase(file),
          keyStore: _Key(),
          initialLanguage: 'en');
      expect(
          (await DriftUserSettingsRepository(db).getSettings()).language, 'ar',
          reason: 'a seed preference must never overwrite an existing choice');
    } finally {
      await db?.close();
      await dir.delete(recursive: true);
    }
  });
}
