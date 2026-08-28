import 'dart:io';

import 'package:drift/native.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/achievement_catalog.dart';
import 'package:money_companion/domain/usecases/gamification_rules.dart';

/// F-023 + F-022 / OD-03 — one gamification vocabulary.
///
/// The client and server shipped two incompatible universes:
///
/// * **Achievements** — the server awards `first_transaction`,
///   `tenth_transaction`, `century_transaction`
///   (`supabase/migrations/0074_gamification_atomic_award.sql`). The client
///   catalog held six entirely different keys. The intersection was **empty**,
///   so every server award landed on `local == null` and was silently dropped:
///   no row updated, no notification, no error.
///
/// * **Levels** — the client used five fixed thresholds
///   `[0, 200, 600, 1500, 3500]`; the server uses an UNBOUNDED
///   `floor(sqrt(xp/100)) + 1`. Above 3500 XP they diverge, and a naive
///   `levelKeys[level - 1]` would throw RangeError on a server level of 6+.
///
/// OD-03: build the canonical contract rather than preserving either side.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  group('F-023 — one achievement vocabulary', () {
    test('the catalog contains the server-awarded keys', () {
      // These are the ONLY keys the server can award. If the client cannot
      // represent them, a server award has nowhere to land.
      final keys = AchievementCatalog.all.map((a) => a.key).toSet();
      for (final serverKey in const [
        'first_transaction',
        'tenth_transaction',
        'century_transaction',
      ]) {
        expect(keys, contains(serverKey),
            reason: 'the server awards $serverKey; a missing local row is why '
                'unlocks were invisible');
      }
    });

    test('the catalog keeps the client-authored keys', () {
      // The union is the canonical vocabulary: both sets are legitimate product
      // features, so neither side is discarded.
      final keys = AchievementCatalog.all.map((a) => a.key).toSet();
      for (final clientKey in const [
        'first_budget',
        'streak_7_days',
        'month_without_overrun',
        'saved_500',
        'first_goal',
        'restaurants_minus_20',
      ]) {
        expect(keys, contains(clientKey));
      }
    });

    test('every key is unique and every key has an Arabic name', () {
      final keys = AchievementCatalog.all.map((a) => a.key).toList();
      expect(keys.toSet().length, keys.length, reason: 'duplicate key');
      for (final a in AchievementCatalog.all) {
        expect(a.nameAr.trim(), isNotEmpty, reason: '${a.key} has no name');
      }
    });

    test('the server award list is asserted against the migration itself', () {
      // A new server award key added without a client row would silently vanish
      // exactly as before. Read the migration so the contract is checked, not
      // assumed.
      final sql = File(
        '../supabase/migrations/0074_gamification_atomic_award.sql',
      ).readAsStringSync();
      final awarded = RegExp(r"v_ach := '([a-z_]+)'")
          .allMatches(sql)
          .map((m) => m.group(1)!)
          .toSet();
      expect(awarded, isNotEmpty, reason: 'the migration must award something');
      final keys = AchievementCatalog.all.map((a) => a.key).toSet();
      expect(awarded.difference(keys), isEmpty,
          reason: 'every server-awarded key must exist in the client catalog');
    });
  });

  group('F-022 — the level label must survive the server curve', () {
    test('a level beyond the client tiers does not throw', () {
      // The server curve is unbounded: 10_000 XP is level 11. Indexing a
      // five-entry list with that would RangeError.
      for (final level in [1, 5, 6, 11, 99]) {
        expect(() => XpLevelEngine.levelKeyForLevel(level), returnsNormally,
            reason: 'level $level must map to a label');
        expect(XpLevelEngine.levelKeyForLevel(level).trim(), isNotEmpty);
      }
    });

    test('levels above the top tier clamp to the highest tier', () {
      final top = XpLevelEngine.levelKeys.last;
      expect(XpLevelEngine.levelKeyForLevel(XpLevelEngine.levelKeys.length), top);
      expect(XpLevelEngine.levelKeyForLevel(50), top,
          reason: 'a server level past the tiers is still a real level');
    });

    test('level 0 or negative clamps to the first tier, never throws', () {
      expect(XpLevelEngine.levelKeyForLevel(0), XpLevelEngine.levelKeys.first);
      expect(XpLevelEngine.levelKeyForLevel(-3), XpLevelEngine.levelKeys.first);
    });

    test('the mapping agrees with the local engine for in-range levels', () {
      for (var i = 0; i < XpLevelEngine.levelKeys.length; i++) {
        expect(
          XpLevelEngine.levelKeyForLevel(i + 1),
          XpLevelEngine.levelKeys[i],
        );
      }
    });
  });

  test('the sync writes level_key, not just level (F-022 root cause)', () {
    // The pull wrote `total_xp` and `level` and never `level_key`, so the label
    // stayed at the seeded 'beginner' no matter how high the level went.
    final src = File(
      'lib/features/gamification/services/gamification_sync_service.dart',
    ).readAsStringSync();
    final update = src.substring(src.indexOf('UPDATE xp_levels'));
    expect(update.substring(0, 200), contains('level_key'),
        reason: 'writing level without level_key is exactly the frozen label');
  });
  test('an existing install receives newly added achievement keys', () async {
    // The seed used to run only when the table was EMPTY, so an install that
    // already had the original six never received the three server-awarded
    // keys — which is why server unlocks had nowhere to land. Seeding per key
    // must add the missing ones without disturbing existing progress.
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(db.close);

    // Simulate the legacy state: only the original client-authored keys, one of
    // them already unlocked.
    await db.customStatement('DELETE FROM achievements;');
    for (final key in const ['first_budget', 'streak_7_days']) {
      await db.customStatement(
        "INSERT INTO achievements(id, key, name_ar, unlocked_at, progress) "
        "VALUES('legacy-$key', '$key', 'x', "
        "${key == 'first_budget' ? "'2026-01-01T00:00:00Z'" : 'NULL'}, 1.0);",
      );
    }

    await db.reseedAchievementsForTest();

    final rows =
        await db.customSelect('SELECT key, unlocked_at FROM achievements;').get();
    final keys = rows.map((r) => r.read<String>('key')).toSet();
    expect(keys, containsAll(const [
      'first_transaction',
      'tenth_transaction',
      'century_transaction',
    ]));

    final unlocked = rows.firstWhere((r) => r.read<String>('key') == 'first_budget');
    expect(unlocked.readNullable<String>('unlocked_at'), isNotNull,
        reason: 'existing progress must not be reset by the backfill');
  });
}
