// TEMP-PROBE: metadata-only Release diagnostic. Remove before the final fix.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/db/app_database.dart';
import '../security/secure_storage_options.dart';

abstract final class PersistenceProbe {
  static const enabled = bool.fromEnvironment('QA_PERSISTENCE_TRACE');
  static final process = DateTime.now().toUtc().toIso8601String();
  static int sequence = 0;
  static int bootstrapGeneration = 0;
  static int sessionGeneration = 0;
  static int destructiveAttempts = 0;
  static int _operation = 0;
  static Future<void> _tail = Future<void>.value();
  static const reasonKey = #persistenceProbeReason;
  static const transactionKey = #persistenceProbeTransaction;

  // Only code locations, never SQL, values, exception text or personal paths.
  static List<String> callers(StackTrace stack) => stack
      .toString()
      .split('\n')
      .where((line) =>
          line.contains('package:money_companion/') &&
          !line.contains('persistence_probe.dart'))
      .take(16)
      .toList();

  static Future<void> record(String event,
      {Map<String, Object?> fields = const {}, StackTrace? caller}) {
    if (!enabled) return Future<void>.value();
    final data = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'processGeneration': process,
      'sequence': ++sequence,
      'bootstrapGeneration': bootstrapGeneration,
      'sessionGeneration': sessionGeneration,
      'event': event,
      'reason': Zone.current[reasonKey] ?? 'runtime',
      'transaction': Zone.current[transactionKey],
      'caller': callers(caller ?? StackTrace.current),
      ...fields,
    };
    // Flush intent BEFORE execution. Statement success is NOT transaction commit.
    // Readers must ignore a torn final line after termination.
    _tail = _tail.then((_) async {
      try {
        String? auth;
        try {
          auth = Supabase.instance.client.auth.currentUser?.id;
        } catch (_) {}
        data['authPresent'] = auth != null;
        try {
          final owner = await SecureStorageOptions.storage
              .read(key: 'local_data_owner_uid');
          data['ownerPresent'] = owner != null;
          data['ownerAuthStatus'] = owner == null || auth == null
              ? 'not_comparable'
              : owner == auth
                  ? 'match'
                  : 'mismatch';
        } catch (_) {
          data['ownerAuthStatus'] = 'unavailable';
        }
        final dir = await getApplicationDocumentsDirectory();
        await File('${dir.path}/qa_persistence_trace.jsonl').writeAsString(
            '${jsonEncode(data)}\n',
            mode: FileMode.append,
            flush: true);
      } catch (_) {
        // Diagnostic I/O must not reset the app. Missing records invalidate proof.
      }
    });
    return _tail;
  }

  static Future<T> mutation<T>(
      String operation, String domain, Future<T> Function() run,
      {bool destructive = false}) async {
    if (!enabled) return run();
    final id = ++_operation;
    if (destructive) destructiveAttempts++;
    final fields = <String, Object?>{
      'operation': operation,
      'domain': domain,
      'operationId': id,
      'destructive': destructive
    };
    await record('mutation.before', fields: fields, caller: StackTrace.current);
    try {
      final result = await run();
      await record('mutation.succeeded', fields: fields);
      return result;
    } catch (_) {
      await record('mutation.failed', fields: fields);
      rethrow;
    }
  }

  static Future<T> sql<T>(String sql, Future<T> Function() run,
      {AppDatabase? db}) async {
    if (!enabled) return run();
    final verb =
        RegExp(r'^\s*([A-Za-z]+)').firstMatch(sql)?.group(1)?.toUpperCase();
    if (!const {
      'INSERT',
      'UPDATE',
      'DELETE',
      'REPLACE',
      'CREATE',
      'ALTER',
      'DROP',
      'PRAGMA',
      'VACUUM'
    }.contains(verb)) {
      return run();
    }
    final domain = AppDatabase.targetTableOf(sql) ??
        (const {'CREATE', 'ALTER', 'DROP'}.contains(verb)
            ? 'schema'
            : 'database');
    // TEMP-PROBE: bracket the two demonstrated loss domains with counts/value,
    // including inside a transaction; commit records determine durability.
    if (db != null && const {'accounts', 'user_settings'}.contains(domain)) {
      await domainState('statement.state.before', domain, db);
    }
    final result = await mutation(verb!, domain, run,
        destructive: verb == 'DELETE' || verb == 'DROP' || verb == 'REPLACE');
    if (db != null && const {'accounts', 'user_settings'}.contains(domain)) {
      await domainState('statement.state.after', domain, db);
    }
    return result;
  }

  static Future<void> domainState(
      String event, String domain, AppDatabase db) async {
    try {
      final fields = <String, Object?>{
        'domain': domain,
        'count': await db.count(domain)
      };
      if (domain == 'user_settings') {
        final row = await db
            .customSelect('SELECT language FROM user_settings LIMIT 1')
            .getSingleOrNull();
        final language = row?.read<String>('language');
        fields['language'] =
            const {'ar', 'en'}.contains(language) ? language : 'unset_or_other';
      }
      await record(event, fields: fields);
    } catch (_) {
      await record('$event.unavailable', fields: {'domain': domain});
    }
  }

  static Future<void> snapshot(String event, AppDatabase db) async {
    if (!enabled) return;
    try {
      final path =
          '${(await getApplicationSupportDirectory()).path}/money_companion.sqlite';
      final file = File(path);
      final tables = await db
          .customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
          .get();
      final counts = <String, int>{};
      for (final row in tables) {
        final name = row.read<String>('name');
        if (RegExp(r'^[a-z_0-9]+$').hasMatch(name)) {
          counts[name] = await db.count(name);
        }
      }
      final settings = counts.containsKey('user_settings')
          ? await db
              .customSelect('SELECT language FROM user_settings LIMIT 1')
              .getSingleOrNull()
          : null;
      final language = settings?.read<String>('language');
      final theme =
          await SecureStorageOptions.storage.read(key: 'app_theme_mode');
      await record(event, fields: {
        'dbPath': path,
        'dbExists': await file.exists(),
        'dbSize': await file.exists() ? await file.length() : null,
        'walPresent': await File('$path-wal').exists(),
        'shmPresent': await File('$path-shm').exists(),
        'counts': counts,
        'language':
            const {'ar', 'en'}.contains(language) ? language : 'unset_or_other',
        'theme': const {'light', 'dark', 'system'}.contains(theme)
            ? theme
            : 'unset_or_other',
        'destructiveAttempts': destructiveAttempts,
        'schema': (await db.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
      });
    } catch (_) {
      await record('$event.snapshot_unavailable');
    }
  }
}
