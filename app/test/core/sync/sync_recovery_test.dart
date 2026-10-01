import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/core/sync/sync_recovery.dart';
import 'package:money_companion/core/sync/sync_wakeup.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/planning_sync/services/outbox_queue_factory.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthException, AuthRetryableFetchException, PostgrestException;

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

const _t = '2026-06-01T10:00:00.000Z';
const _later = '2026-06-01T12:00:00.000Z';

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });
  tearDown(() async => db.close());

  Future<void> ledgerRow(
    String id, {
    String status = 'pending',
    String? failureClass,
    String? lastError,
    int attempts = 0,
    String? nextRetry,
    int? inFlight,
    String updatedAt = _t,
  }) =>
      db.customStatement('''
        INSERT INTO ledger_sync_outbox(id, transaction_id, operation,
          payload_json, attempt_count, last_error, created_at, updated_at,
          next_retry_at, status, failure_class, op_seq, in_flight_seq)
        VALUES ('$id', 'tx-$id', 'update', '{}', $attempts,
          ${lastError == null ? 'NULL' : "'$lastError'"}, '$_t', '$updatedAt',
          ${nextRetry == null ? 'NULL' : "'$nextRetry'"}, '$status',
          ${failureClass == null ? 'NULL' : "'$failureClass'"}, 1,
          ${inFlight ?? 'NULL'});
      ''');

  Future<void> planningRow(
    String id, {
    String status = 'pending',
    String? failureClass,
    String? lastError,
    int attempts = 0,
    String? nextRetry,
  }) =>
      db.customStatement('''
        INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation,
          payload_json, attempt_count, last_error, created_at, updated_at,
          next_retry_at, status, failure_class, op_seq)
        VALUES ('$id', 'goals', 'e-$id', 'update', '{}', $attempts,
          ${lastError == null ? 'NULL' : "'$lastError'"}, '$_t', '$_t',
          ${nextRetry == null ? 'NULL' : "'$nextRetry'"}, '$status',
          ${failureClass == null ? 'NULL' : "'$failureClass'"}, 1);
      ''');

  Future<Map<String, Object?>> row(String table, String id) async => (await db
          .customSelect("SELECT * FROM $table WHERE id = '$id';")
          .getSingle())
      .data;

  Future<String> status(String table, String id) async =>
      (await row(table, id))['status']! as String;

  Future<void> mapping(String n, String syncStatus,
          {int permanent = 0, int attempts = 0}) =>
      db.customStatement('''
        INSERT INTO sender_bank_mappings(
          id, sender_id, normalized_sender_id, bank_key, suggested_bank_name,
          suggested_country, confidence, status, source, first_seen_at,
          last_seen_at, confirmed_at, created_at, updated_at, sync_status,
          sync_attempt_count, sync_next_retry_at, sync_permanent,
          sync_failure_class
        ) VALUES (
          'loc-$n', '$n', '$n', 'bank', 'Bank', 'SA', 0.9, 'confirmed',
          'user_manual', '$_t', '$_t', '$_t', '$_t', '$_t', '$syncStatus',
          $attempts, '2099-01-01T00:00:00Z', $permanent, 'serverError'
        );
      ''');

  SyncRecoveryService service({
    void Function()? wakeup,
    Future<void> Function()? reprobe,
  }) =>
      SyncRecoveryService(
        db: db,
        ledgerQueue: buildLedgerOutboxQueue(db),
        planningQueue: buildPlanningOutboxQueue(db),
        reprobeCapabilities: reprobe ?? () async {},
        wakeup: wakeup ?? () {},
      );

  group('Retry', () {
    test('re-arms exactly the intended classes and triggers the wakeup',
        () async {
      // Ledger dead letters.
      await ledgerRow('l-server', status: 'dead_letter',
          failureClass: 'serverError', attempts: 12, lastError: 'boom');
      await ledgerRow('l-valid', status: 'dead_letter',
          failureClass: 'permanentValidation', attempts: 1);
      await ledgerRow('l-check', status: 'dead_letter',
          failureClass: kFailServerCheckViolation);
      await ledgerRow('l-dup', status: 'dead_letter',
          failureClass: kFailDuplicateBusinessKey);
      await ledgerRow('l-unsup', status: 'dead_letter',
          failureClass: 'permanentValidation',
          lastError: 'unsupported_operation: Unsupported operation');
      // Planning dead letters.
      await planningRow('p-schema', status: 'dead_letter',
          failureClass: 'unsupportedSchema', attempts: 3);
      await planningRow('p-dup', status: 'dead_letter',
          failureClass: kFailDuplicateBusinessKey);
      await planningRow('p-unsup', status: 'dead_letter',
          failureClass: 'permanentValidation',
          lastError: 'unsupported_operation: goal_contributions delete');
      // Auth-parked + rows that must NOT be touched.
      await ledgerRow('l-auth', status: 'parked', failureClass: kParkAuthRequired);
      await planningRow('p-auth', status: 'parked', failureClass: kParkAuthRequired);
      await ledgerRow('l-owner', status: 'parked', failureClass: kParkOwnerMismatch);
      await ledgerRow('l-fx', status: 'parked',
          failureClass: kParkAwaitingServerFxSupport);
      await planningRow('p-dep', status: 'parked', failureClass: kParkDependencyWait);
      // Backoff wait is dropped on a user Retry.
      await ledgerRow('l-wait', failureClass: 'transientNetwork',
          attempts: 2, nextRetry: '2099-01-01T00:00:00Z');
      // Sender mappings: terminal + retrying are reset, synced is untouched.
      await mapping('m-term', 'failed', permanent: 1, attempts: 12);
      await mapping('m-retry', 'failed', attempts: 2);
      await mapping('m-ok', 'synced');

      var wakeups = 0;
      var probes = 0;
      final result = await service(
        wakeup: () => wakeups++,
        reprobe: () async => probes++,
      ).retryNow();

      // Ledger dead letters.
      expect(await status('ledger_sync_outbox', 'l-server'), 'pending');
      expect((await row('ledger_sync_outbox', 'l-server'))['attempt_count'], 0);
      expect(await status('ledger_sync_outbox', 'l-valid'), 'pending');
      expect(await status('ledger_sync_outbox', 'l-check'), 'pending');
      expect(await status('ledger_sync_outbox', 'l-dup'), 'dead_letter');
      expect(await status('ledger_sync_outbox', 'l-unsup'), 'dead_letter');
      // Planning dead letters.
      expect(await status('planning_sync_outbox', 'p-schema'), 'pending');
      expect(await status('planning_sync_outbox', 'p-dup'), 'dead_letter');
      expect(await status('planning_sync_outbox', 'p-unsup'), 'dead_letter');
      // Parked rows.
      expect(await status('ledger_sync_outbox', 'l-auth'), 'pending');
      expect(await status('planning_sync_outbox', 'p-auth'), 'pending');
      expect(await status('ledger_sync_outbox', 'l-owner'), 'parked');
      expect(await status('ledger_sync_outbox', 'l-fx'), 'parked');
      expect(await status('planning_sync_outbox', 'p-dep'), 'parked');
      // Backoff cleared, attempts preserved.
      final wait = await row('ledger_sync_outbox', 'l-wait');
      expect(wait['next_retry_at'], isNull);
      expect(wait['attempt_count'], 2);
      // Sender mappings.
      final term = await row('sender_bank_mappings', 'loc-m-term');
      expect(term['sync_status'], 'pending');
      expect(term['sync_permanent'], 0);
      expect(term['sync_attempt_count'], 0);
      expect(term['sync_next_retry_at'], isNull);
      expect((await row('sender_bank_mappings', 'loc-m-retry'))['sync_status'],
          'pending');
      expect((await row('sender_bank_mappings', 'loc-m-ok'))['sync_status'],
          'synced');

      expect(wakeups, 1, reason: 'Retry wakes the sync orchestrator once');
      expect(probes, 1, reason: 'Retry forces a capability re-probe');
      expect(result.deadLettersRearmed, 4);
      expect(result.authParkedRearmed, 2);
      expect(result.mappingsRearmed, 2);
    });

    test('a failing capability probe never fails Retry', () async {
      var wakeups = 0;
      await service(
        wakeup: () => wakeups++,
        reprobe: () async => throw StateError('offline'),
      ).retryNow();
      expect(wakeups, 1);
    });
  });

  group('Auth failures', () {
    test('classification covers 401/403/42501/JWT/AuthException', () {
      for (final code in ['401', '403', '42501', 'PGRST301']) {
        expect(
            classifyOutboxError(PostgrestException(message: 'x', code: code)),
            OutboxFailureClass.auth,
            reason: code);
      }
      expect(classifyOutboxError(const AuthException('JWT expired')),
          OutboxFailureClass.auth);
      expect(classifyOutboxError(StateError('JWT expired')),
          isNot(OutboxFailureClass.auth)); // StateError path is unchanged
      expect(classifyOutboxError(Exception('jwt expired')),
          OutboxFailureClass.auth);
      // A refresh that failed on the NETWORK is not an auth rejection.
      expect(
          classifyOutboxError(AuthRetryableFetchException(message: 'offline')),
          OutboxFailureClass.transientNetwork);
    });

    test('ledger: auth failure parks without consuming an attempt, forever',
        () async {
      await ledgerRow('l1', attempts: 3, inFlight: 1);
      final q = buildLedgerOutboxQueue(db);
      for (var i = 0; i < kOutboxMaxAttempts + 5; i++) {
        // Re-arm then fail again, far past the dead-letter bound.
        await db.customStatement(
            "UPDATE ledger_sync_outbox SET status = 'pending' WHERE id = 'l1'");
        await q.markFailed('l1', 'jwt expired', OutboxFailureClass.auth);
      }
      final r = await row('ledger_sync_outbox', 'l1');
      expect(r['status'], 'parked');
      expect(r['failure_class'], kParkAuthRequired);
      expect(r['attempt_count'], 3, reason: 'no attempt consumed');
      expect(r['last_error'], isNull, reason: 'raw error is not retained');
      expect(r['next_retry_at'], isNull);
      expect(r['in_flight_seq'], isNull);
    });

    test('planning: auth failure parks without consuming an attempt',
        () async {
      await planningRow('p1', attempts: 11);
      await buildPlanningOutboxQueue(db)
          .markFailed('p1', '42501', OutboxFailureClass.auth);
      final r = await row('planning_sync_outbox', 'p1');
      expect(r['status'], 'parked');
      expect(r['failure_class'], kParkAuthRequired);
      expect(r['attempt_count'], 11);
    });

    test('auth-parked rows are counted in parkedByReason', () async {
      await ledgerRow('l1', status: 'parked', failureClass: kParkAuthRequired);
      await planningRow('p1', status: 'parked', failureClass: kParkAuthRequired);
      final c = await SyncHealth.queueCounts(db);
      expect(c.parkedByReason[kParkAuthRequired], 2);
      expect(c.parked, 2);
    });

    test('generic reArmParked leaves auth-parked rows for the auth event',
        () async {
      await ledgerRow('l1', status: 'parked', failureClass: kParkAuthRequired);
      expect(await buildLedgerOutboxQueue(db).reArmParked(), 0);
      expect(await status('ledger_sync_outbox', 'l1'), 'parked');
    });

    test('re-arms on the authenticated-session event, and only auth rows',
        () async {
      await ledgerRow('l-auth', status: 'parked', failureClass: kParkAuthRequired);
      await planningRow('p-auth', status: 'parked', failureClass: kParkAuthRequired);
      await ledgerRow('l-owner', status: 'parked', failureClass: kParkOwnerMismatch);
      await ledgerRow('l-dead', status: 'dead_letter',
          failureClass: 'serverError');
      var wakeups = 0;
      final sub = bindAuthRearm(
        AuthSessionValid.events,
        service(wakeup: () => wakeups++),
      );
      AuthSessionValid.notify();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(await status('ledger_sync_outbox', 'l-auth'), 'pending');
      expect(await status('planning_sync_outbox', 'p-auth'), 'pending');
      expect(await status('ledger_sync_outbox', 'l-owner'), 'parked');
      expect(await status('ledger_sync_outbox', 'l-dead'), 'dead_letter');
      expect(wakeups, 1);
    });

    test('no auth-parked rows -> the event does not wake the orchestrator',
        () async {
      var wakeups = 0;
      final n = await service(wakeup: () => wakeups++).rearmAuthParked();
      expect(n, 0);
      expect(wakeups, 0);
    });
  });

  group('queueCounts A-5 fields', () {
    test('dead letter reasons, in-flight, last mutation, next retry',
        () async {
      await ledgerRow('l-dup', status: 'dead_letter',
          failureClass: kFailDuplicateBusinessKey);
      await ledgerRow('l-unsup', status: 'dead_letter',
          failureClass: 'permanentValidation',
          lastError: 'unsupported_operation: x');
      await planningRow('p-srv', status: 'dead_letter',
          failureClass: 'serverError');
      await ledgerRow('l-flight', inFlight: 1, updatedAt: _later,
          nextRetry: '2030-01-01T00:00:00.000Z');
      await mapping('m-term', 'failed', permanent: 1);
      await mapping('m-retry', 'failed');

      final c = await SyncHealth.queueCounts(db);
      expect(c.deadLetter, 3);
      expect(c.deadLetterByReason, {
        kFailDuplicateBusinessKey: 1,
        kFailUnsupportedOperation: 1,
        'serverError': 1,
      });
      expect(c.inFlight, 1);
      expect(c.lastLocalMutationAt, DateTime.parse(_later));
      expect(c.nextRetryAt, DateTime.parse('2030-01-01T00:00:00.000Z'));
      expect(c.senderMappingsFailed, 2);
      expect(c.senderMappingsPermanentFailed, 1);
    });

    test('empty database has no mutation / retry / in-flight', () async {
      final c = await SyncHealth.queueCounts(db);
      expect(c.lastLocalMutationAt, isNull);
      expect(c.nextRetryAt, isNull);
      expect(c.inFlight, 0);
      expect(c.deadLetterByReason, isEmpty);
    });
  });
}
