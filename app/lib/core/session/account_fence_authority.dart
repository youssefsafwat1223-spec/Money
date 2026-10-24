import 'dart:convert';

import '../../data/db/sql_value_codec.dart';
import '../../data/repositories/drift_smart_inbox_repository.dart';
import '../utils/id_generator.dart';
import 'package:flutter/foundation.dart';

import '../privacy/cloud_egress_gate.dart';
import '../../data/db/app_database.dart';
import 'account_fence_store.dart';
import 'account_scope.dart';
import 'admission_authority.dart';
import 'app_session.dart';

class AccountFenceDeniedException implements Exception {
  const AccountFenceDeniedException();
  @override
  String toString() => 'AccountFenceDeniedException';
}

/// Only a real, coherently captured session/scope lifetime can produce a handle.
class AccountFenceHandle {
  AccountFenceHandle._(this._authority, this._session, this._host, this._scope,
      this._capability, this._ownerToken, this._egressEpoch, this._bindingEpoch);
  final AccountFenceAuthority _authority;
  final AppSession _session;
  final AccountScopeHost _host;
  final AccountScope _scope;
  final AdmissionAuthority _capability;
  final String _ownerToken;
  final int _egressEpoch;
  final int _bindingEpoch;
}

class AccountFenceResult {
  const AccountFenceResult({required this.accepted, required this.complete});
  final bool accepted;
  final bool complete;
}

/// A captured pending status edit, not a remote receipt or a parking grant.
class AccountFenceSmartInboxIntent {
  AccountFenceSmartInboxIntent._(this._handle, this._database, this._operationId,
      this.localId, this.serverId, this.status, this.editStamp);
  final String localId, serverId, status, editStamp;
  final AccountFenceHandle _handle;
  final AppDatabase _database;
  final String _operationId;
  bool _used = false;
}

/// One immutable pending event, not a remote receipt or a parking grant.
class AccountFenceEngagementIntent {
  AccountFenceEngagementIntent._(this._handle, this._database, this._operationId,
      this.eventId, this.eventType, this.occurredAt, this.businessKey, this.eventVersion);
  final String eventId, eventType, occurredAt;
  final String? businessKey;
  final int eventVersion;
  final AccountFenceHandle _handle;
  final AppDatabase _database;
  final String _operationId;
  bool _used = false;
}

/// A particular immutable sender batch, not one receipt/parking grant per row.
class AccountFenceSenderMappingIntent {
  AccountFenceSenderMappingIntent._(this._handle, this._database, this._operationId,
      List<Map<String, Object?>> rows)
      : rows = List.unmodifiable(rows.map((row) => Map<String, Object?>.unmodifiable(row)));
  final List<Map<String, Object?>> rows;
  final AccountFenceHandle _handle;
  final AppDatabase _database;
  final String _operationId;
  bool _used = false;
}

/// One exact existing event; this is not proof that an SDK request occurred.
class AccountFenceNotificationIntent {
  AccountFenceNotificationIntent._(this._handle, this._database, this._operationId,
      Map<String, Object?> snapshot) : snapshot = Map.unmodifiable(snapshot);
  final AccountFenceHandle _handle;
  final AppDatabase _database;
  final String _operationId;
  final Map<String, Object?> snapshot;
  bool _used = false;
}

/// One exact local default-account command: the unique active default row, its
/// server target, and the FULL row as read inside a tracked local transaction.
/// [_operationId] is a local denial-record correlation ONLY — it is never sent
/// to the server and is not an idempotency, replay or queue identity. This is
/// not proof that an SDK request occurred.
class AccountFenceDefaultAccountIntent {
  AccountFenceDefaultAccountIntent._(this._handle, this._database, this._operationId,
      this.localId, this.serverId, Map<String, Object?> row)
      : snapshot = Map.unmodifiable(row);
  final String localId, serverId;
  final Map<String, Object?> snapshot;
  final AccountFenceHandle _handle;
  final AppDatabase _database;
  final String _operationId;
  bool _used = false;
}

/// One-use permission for ONLY the exact rejected ledger intent's parking.
/// It is not a positive admission capability and cannot authorize dispatch/ACK.
class AccountFenceParking {
  AccountFenceParking._(this._database, this._rowId, this._transactionId,
      this._ownerUid, this._opSeq, this._operationId, this._state);
  final AppDatabase _database;
  final String _rowId;
  final String _transactionId;
  final String _ownerUid;
  final int _opSeq;
  final String _operationId;
  final AccountFenceState _state;
  bool _used = false;
  bool _settled = false;

  void requireExact(AppDatabase database, {required String rowId,
      required String transactionId, required String? ownerUid,
      required int opSeq, required String? operationId,
      required AccountFenceState state}) {
    if (_used || _settled || !identical(database, _database) ||
        database.lifecycleState != DatabaseLifecycleState.open ||
        rowId != _rowId || transactionId != _transactionId ||
        ownerUid != _ownerUid || opSeq != _opSeq ||
        operationId != _operationId || state != _state) {
      throw const StaleAdmissionException();
    }
    _used = true;
  }
}

class AccountFenceLedgerResult {
  const AccountFenceLedgerResult({required this.accepted,
      required this.parked, required this.complete});
  final bool accepted;
  final bool parked;
  final bool complete;
}

class AccountFenceAccountsParking {
  AccountFenceAccountsParking._(this._database, this._rowId, this._entityType, this._entityId,
      this._ownerUid, this._opSeq, this._operationId, this._state);
  final AppDatabase _database;
  final String _rowId;
  final String _entityType;
  final String _entityId;
  final String _ownerUid;
  final int _opSeq;
  final String _operationId;
  final AccountFenceState _state;
  bool _used = false;
  bool _settled = false;

  void requireExact(AppDatabase database, {required String rowId,
      required String entityType, required String entityId, required String? ownerUid,
      required int opSeq, required String? operationId,
      required AccountFenceState state}) {
    if (_used || _settled || !identical(database, _database) ||
        database.lifecycleState != DatabaseLifecycleState.open ||
        rowId != _rowId || entityType != _entityType || entityId != _entityId ||
        ownerUid != _ownerUid || opSeq != _opSeq ||
        operationId != _operationId || state != _state) {
      throw const StaleAdmissionException();
    }
    _used = true;
  }
}

class AccountFenceAccountsResult {
  const AccountFenceAccountsResult({required this.accepted,
      required this.parked, required this.complete});
  final bool accepted;
  final bool parked;
  final bool complete;
}

enum _ParentRoute { ordinary, boundOff, prebindOff }

/// Snapshot evidence only; positive operations still need the original handle.
class AccountFenceParentIntent {
  AccountFenceParentIntent._(this._handle, this.database, this.rowId,
      this.entityType, this.entityId, this.ownerUid, this.opSeq, this.operationId,
      this._route, this.offTarget, Map<String, dynamic>? offPayload)
      : offPayload = offPayload == null ? null : Map.unmodifiable(offPayload);
  final AccountFenceHandle _handle;
  final AppDatabase database;
  final String rowId;
  final String entityType;
  final String entityId;
  final String? ownerUid;
  final int opSeq;
  final String operationId;
  final _ParentRoute _route;
  final String? offTarget;
  final Map<String, dynamic>? offPayload;
  bool _denialUsed = false;
  bool get isBoundOff => _route == _ParentRoute.boundOff;
  bool get isPrebindOff => _route == _ParentRoute.prebindOff;
}

class AccountFenceParentParking {
  AccountFenceParentParking._(this._intent, this._state);
  final AccountFenceParentIntent _intent;
  final AccountFenceState _state;
  bool _used = false;
  bool _settled = false;
  void requireExact(AppDatabase database, {required String rowId,
      required String entityType, required String entityId, required String? ownerUid,
      required int opSeq, required String? operationId, required AccountFenceState state}) {
    if (_used || _settled || !identical(database, _intent.database) ||
        database.lifecycleState != DatabaseLifecycleState.open ||
        rowId != _intent.rowId || entityType != _intent.entityType ||
        entityId != _intent.entityId || ownerUid != _intent.ownerUid ||
        opSeq != _intent.opSeq || operationId != _intent.operationId || state != _state) {
      throw const StaleAdmissionException();
    }
    _used = true;
  }
}

class AccountFenceParentResult {
  const AccountFenceParentResult({required this.accepted, required this.parked,
      required this.complete});
  final bool accepted;
  final bool parked;
  final bool complete;
}

/// Closed child intent; proves exact row/lifetime, not remote operation origin.
class AccountFenceChildIntent {
  AccountFenceChildIntent._(this._handle,this.database,this.rowId,this.entityType,
      this.entityId,this.ownerUid,this.opSeq,this.operationId);
  final AccountFenceHandle _handle;
  final AppDatabase database;
  final String rowId;
  final String entityType;
  final String entityId;
  final String ownerUid;
  final int opSeq;
  final String operationId;
  bool _denialUsed=false;
}
class AccountFenceChildParking {
  AccountFenceChildParking._(this._intent,this._state);
  final AccountFenceChildIntent _intent;
  final AccountFenceState _state;
  bool _used=false;
  bool _settled=false;
  void requireExact(AppDatabase database,{required String rowId,required String entityType,
      required String entityId,required String? ownerUid,required int opSeq,
      required String? operationId,required AccountFenceState state}){
    if(_used||_settled||!identical(database,_intent.database)||database.lifecycleState!=DatabaseLifecycleState.open||
        rowId!=_intent.rowId||entityType!=_intent.entityType||entityId!=_intent.entityId||ownerUid!=_intent.ownerUid||
        opSeq!=_intent.opSeq||operationId!=_intent.operationId||state!=_state){throw const StaleAdmissionException();}
    _used=true;
  }
}
class AccountFenceChildResult {
  const AccountFenceChildResult({required this.accepted,required this.parked,required this.complete});
  final bool accepted;
  final bool parked;
  final bool complete;
}

/// Shared application-owned denial component. Ledger, account, planning-parent
/// child and Smart Inbox status mutations are integrated; running pull internals remain outside
/// this partial unit. It provides no
/// hold release or local read authority.
class AccountFenceAuthority {
  AccountFenceAuthority._(this.store);
  static AccountFenceAuthority _shared = AccountFenceAuthority._(AccountFenceStore.shared);
  static AccountFenceAuthority get shared => _shared;
  static int _bindingEpoch = 0;
  final AccountFenceStore store;
  Future<bool> _cleanup = Future<bool>.value(true);
  bool _cleanupFailed = false;
  int _pendingCleanup = 0;

  bool permits(String uid) => !_cleanupFailed && _pendingCleanup == 0 &&
      store.allows(AccountFenceStore.ownerDigest(uid));

  Future<bool> initialize() async {
    while (true) {
      final cleanup = _cleanup;
      if (!await cleanup || !await store.load()) return false;
      if (!identical(cleanup, _cleanup)) continue;
      return !_cleanupFailed && _pendingCleanup == 0 && store.ready;
    }
  }

  /// Waiters never enter AppSession's tracked local-operation set. Capture the
  /// intended identity before calling; revalidate it on both sides of awaits.
  Future<void> guard(String uid, {bool Function()? current}) async {
    void check() {
      if (!(current?.call() ?? true)) throw const StaleAdmissionException();
    }
    while (true) {
      check();
      final cleanup = _cleanup;
      if (!await cleanup) throw const AccountFenceDeniedException();
      check();
      if (!await store.load()) throw const AccountFenceDeniedException();
      check();
      if (!identical(cleanup, _cleanup)) continue;
      if (!permits(uid)) throw const AccountFenceDeniedException();
      return;
    }
  }

  /// A scope transition already owns the host's serial lane. Never wait for
  /// cleanup queued in that same lane: refusal releases the turn to cleanup.
  void requireInHostTurn(String uid, {required bool current}) {
    if (!current) throw const StaleAdmissionException();
    if (!permits(uid)) throw const AccountFenceDeniedException();
  }

  Future<AccountFenceHandle?> capture(AppSession session, AccountScopeHost host) async {
    final scope = host.current;
    final capability = session.captureLocalWorkAuthority();
    if (scope?.uid == null || scope?.location == null || capability == null) return null;
    final token = session.accountFenceOwnerToken(host, scope!, capability);
    if (token == null) return null;
    final handle = AccountFenceHandle._(this, session, host, scope, capability,
        token, CloudEgressGate.instance.epoch, _bindingEpoch);
    if (!_current(handle) || !capability.isCurrent) return null;
    final (String?, String?) proof;
    try {
      proof = await session.readAccountFenceOwnerProof();
    } catch (_) {
      return null;
    }
    if (!_current(handle) || !capability.isCurrent ||
        proof.$1 != scope.uid || proof.$2 != token) {
      return null;
    }
    return handle;
  }

  Future<AccountFenceHandle?> captureForDatabase(AppSession session,
      AppDatabase database) {
    final host = session.accountFenceHostForDatabase(database);
    return host == null ? Future.value(null) : capture(session, host);
  }

  String ownerUid(AccountFenceHandle handle) => handle._scope.uid!;

  bool isCurrentForDatabase(AccountFenceHandle handle, AppDatabase database) =>
      identical(handle._scope.database, database) && _current(handle) &&
      handle._capability.isCurrent && permits(handle._scope.uid!);

  void requireCurrentForDatabase(AccountFenceHandle handle, AppDatabase database) {
    if (!isCurrentForDatabase(handle, database)) {
      throw const StaleAdmissionException();
    }
  }

  Future<T> runCurrentLocal<T>(AccountFenceHandle handle, AppDatabase database,
      Future<T> Function() action) {
    requireCurrentForDatabase(handle, database);
    return handle._session.runAdmittedLocalOperation(handle._capability, action);
  }

  /// Capture/register/accept are synchronous before the first parking await.
  /// Cleanup is awaited ONLY after the reservation has been released.
  Future<AccountFenceLedgerResult> acceptLedgerDenial(AccountFenceHandle handle,
      AppDatabase database, AccountFenceState state, {required String rowId,
      required String transactionId, required String? ownerUid,
      required int opSeq, required String operationId,
      required Future<bool> Function(AccountFenceParking ticket) park}) async {
    if (!_current(handle) || !identical(handle._scope.database, database) ||
        ownerUid != handle._scope.uid || !_operationId.hasMatch(operationId)) {
      return const AccountFenceLedgerResult(accepted: false, parked: false, complete: false);
    }
    final settle = handle._session.reserveAccountFenceParking(handle._host,
        handle._scope, handle._capability, handle._ownerToken, handle._egressEpoch);
    final ticket = AccountFenceParking._(database, rowId, transactionId,
        ownerUid!, opSeq, operationId, state);
    ({bool accepted, Future<bool> cleanup})? begun;
    var parked = false;
    try {
      begun = _beginAcceptance(handle, state, operationId: operationId);
      if (begun.accepted) parked = await park(ticket);
    } catch (_) {
      // Restriction is never rolled back; failure is truthfully incomplete.
    } finally {
      ticket._settled = true;
      settle();
    }
    if (begun == null || !begun.accepted) {
      return const AccountFenceLedgerResult(accepted: false, parked: false, complete: false);
    }
    final closedAndDurable = await begun.cleanup;
    return AccountFenceLedgerResult(accepted: true, parked: parked,
        complete: parked && closedAndDurable);
  }

  Future<AccountFenceAccountsResult> acceptAccountsDenial(AccountFenceHandle handle,
      AppDatabase database, AccountFenceState state, {required String rowId,
      required String entityType, required String entityId, required String? ownerUid,
      required int opSeq, required String operationId,
      required Future<bool> Function(AccountFenceAccountsParking ticket) park}) async {
    if ((entityType != 'account' && entityType != 'account_default_command') ||
        rowId.isEmpty || entityId.isEmpty || opSeq < 0 || !_current(handle) || !identical(handle._scope.database, database) ||
        ownerUid != handle._scope.uid || !_operationId.hasMatch(operationId)) {
      return const AccountFenceAccountsResult(accepted: false, parked: false, complete: false);
    }
    final settle = handle._session.reserveAccountFenceParking(handle._host,
        handle._scope, handle._capability, handle._ownerToken, handle._egressEpoch);
    final ticket = AccountFenceAccountsParking._(database, rowId, entityType, entityId,
        ownerUid!, opSeq, operationId, state);
    ({bool accepted, Future<bool> cleanup})? begun;
    var parked = false;
    try {
      begun = _beginAcceptance(handle, state, operationId: operationId);
      if (begun.accepted) parked = await park(ticket);
    } catch (_) {
      // Restriction is never rolled back; failure is truthfully incomplete.
    } finally {
      ticket._settled = true;
      settle();
    }
    if (begun == null || !begun.accepted) {
      return const AccountFenceAccountsResult(accepted: false, parked: false, complete: false);
    }
    final closedAndDurable = await begun.cleanup;
    return AccountFenceAccountsResult(accepted: true, parked: parked,
        complete: parked && closedAndDurable);
  }

  static const _parentLanes = {'budget', 'subscription', 'goal', 'plan',
      'card', 'category', 'settings'};

  Future<AccountFenceParentIntent?> captureParentIntent(AccountFenceHandle handle,
      AppDatabase database, {required String rowId, required String entityType,
      required String entityId, required int opSeq, required String operationId}) =>
      _captureParentIntent(handle, database, rowId: rowId, entityType: entityType,
          entityId: entityId, opSeq: opSeq, operationId: operationId, settingsOff: false);

  Future<AccountFenceParentIntent?> captureParentSettingsOffIntent(AccountFenceHandle handle,
      AppDatabase database, {required String rowId, required String entityId,
      required int opSeq, required String operationId}) =>
      _captureParentIntent(handle, database, rowId: rowId, entityType: 'settings',
          entityId: entityId, opSeq: opSeq, operationId: operationId, settingsOff: true);

  Future<AccountFenceParentIntent?> _captureParentIntent(AccountFenceHandle handle,
      AppDatabase database, {required String rowId, required String entityType,
      required String entityId, required int opSeq, required String operationId,
      required bool settingsOff}) async {
    if (!_parentLanes.contains(entityType) || rowId.isEmpty || entityId.isEmpty ||
        opSeq < 0 || !_operationId.hasMatch(operationId)) {
      return null;
    }
    final intent = await runCurrentLocal(handle, database, () => database.transaction(() async {
      final row = await database.customSelect("SELECT owner_uid, operation, payload_json "
          "FROM planning_sync_outbox WHERE id = ${sqlString(rowId)} "
          "AND entity_type = ${sqlString(entityType)} AND entity_id = ${sqlString(entityId)} "
          "AND status = 'pending' AND op_seq = $opSeq AND in_flight_seq = $opSeq "
          "AND operation_id = ${sqlString(operationId)};").getSingleOrNull();
      if (row == null) return null;
      final owner = row.readNullable<String>('owner_uid');
      if (owner != null && owner != ownerUid(handle)) return null;
      if (!settingsOff) {
        if (owner != ownerUid(handle)) return null;
        return AccountFenceParentIntent._(handle, database, rowId, entityType,
            entityId, owner, opSeq, operationId, _ParentRoute.ordinary, null, null);
      }
      if (entityType != 'settings') return null;
      final payload = (jsonDecode(row.read<String>('payload_json')) as Map).cast<String, dynamic>();
      if (payload['local_id'] != 'user_settings') return null;
      final cloudOff = payload['cloud_processing_enabled'] == false;
      final aiOff = payload['ai_consent_granted'] == false;
      if (!cloudOff && !aiOff) return null;
      final op = row.read<String>('operation');
      final target = await database.customSelect("SELECT id, server_id FROM user_settings LIMIT 1;").getSingleOrNull();
      if (target == null || target.read<String>('id') != entityId) return null;
      final serverId = target.readNullable<String>('server_id');
      if (payload['consent_only'] == true && op == 'create' && serverId == null) {
        return AccountFenceParentIntent._(handle, database, rowId, entityType,
            entityId, owner, opSeq, operationId, _ParentRoute.prebindOff, null, {
              'user_id': ownerUid(handle), 'local_id': 'user_settings',
              'ai_consent_granted': payload['ai_consent_granted'] == true,
              'cloud_processing_enabled': payload['cloud_processing_enabled'] == true,
              if (payload['consent_version'] is int) 'consent_version': payload['consent_version'],
            });
      }
      if (payload['consent_only'] != true && (op == 'create' || op == 'update') &&
          serverId != null && serverId.isNotEmpty) {
        return AccountFenceParentIntent._(handle, database, rowId, entityType,
            entityId, owner, opSeq, operationId, _ParentRoute.boundOff, serverId, {
              'ai_consent_granted': false,
              if (cloudOff) 'cloud_processing_enabled': false,
            });
      }
      return null;
    }));
    requireCurrentForDatabase(handle, database);
    return intent;
  }

  Future<AccountFenceParentResult> acceptParentDenial(AccountFenceHandle handle,
      AppDatabase database, AccountFenceParentIntent intent, AccountFenceState state,
      {required Future<bool> Function(AccountFenceParentParking) park}) async {
    if (!_current(handle) || !identical(handle, intent._handle) ||
        !identical(database, intent.database) || !identical(handle._scope.database, database) ||
        !_parentLanes.contains(intent.entityType) || intent._denialUsed ||
        (intent.ownerUid != null && intent.ownerUid != ownerUid(handle)) ||
        (intent.ownerUid == null && intent._route == _ParentRoute.ordinary)) {
      return const AccountFenceParentResult(accepted: false, parked: false, complete: false);
    }
    final settle = handle._session.reserveAccountFenceParking(handle._host,
        handle._scope, handle._capability, handle._ownerToken, handle._egressEpoch);
    intent._denialUsed = true;
    final ticket = AccountFenceParentParking._(intent, state);
    ({bool accepted, Future<bool> cleanup})? begun;
    var parked = false;
    try {
      begun = _beginAcceptance(handle, state, operationId: intent.operationId);
      if (begun.accepted) parked = await park(ticket);
    } catch (_) {
      // Accepted restriction is never rolled back on persistence/parking failure.
    } finally {
      ticket._settled = true;
      settle();
    }
    if (begun == null || !begun.accepted) {
      return const AccountFenceParentResult(accepted: false, parked: false, complete: false);
    }
    final complete = await begun.cleanup;
    return AccountFenceParentResult(accepted: true, parked: parked,
        complete: parked && complete);
  }

  static const _childLanes={'goal_contribution','bill_payment','plan_transaction_link'};
  Future<AccountFenceChildIntent?> captureChildIntent(AccountFenceHandle handle,
      AppDatabase database,{required String rowId,required String entityType,
      required String entityId,required int opSeq,required String operationId})async{
    if(!_childLanes.contains(entityType)||rowId.isEmpty||entityId.isEmpty||opSeq<0||!_operationId.hasMatch(operationId)){return null;}
    final intent=await runCurrentLocal(handle,database,()=>database.transaction(()async{
      final row=await database.customSelect("SELECT owner_uid,payload_json FROM planning_sync_outbox WHERE id=${sqlString(rowId)} "
          "AND entity_type=${sqlString(entityType)} AND entity_id=${sqlString(entityId)} AND status='pending' "
          "AND op_seq=$opSeq AND in_flight_seq=$opSeq AND operation_id=${sqlString(operationId)};").getSingleOrNull();
      if(row==null||row.readNullable<String>('owner_uid')!=ownerUid(handle)){return null;}
      final payload=(jsonDecode(row.read<String>('payload_json'))as Map).cast<String,dynamic>();
      if(entityType=='plan_transaction_link'){
        final plan=payload['local_plan_id'];final transaction=payload['local_transaction_id'];
        if(plan is! String||plan.isEmpty||transaction is! String||transaction.isEmpty||'$plan:$transaction'!=entityId){return null;}
      }else if(payload['local_id']!=entityId){return null;}
      return AccountFenceChildIntent._(handle,database,rowId,entityType,entityId,ownerUid(handle),opSeq,operationId);
    }));
    requireCurrentForDatabase(handle,database);return intent;
  }

  Future<AccountFenceChildResult> acceptChildDenial(AccountFenceHandle handle,
      AppDatabase database, AccountFenceChildIntent intent, AccountFenceState state,
      {required Future<bool> Function(AccountFenceChildParking) park}) async {
    if (!_current(handle) || !identical(handle, intent._handle) ||
        !identical(database, intent.database) || !identical(handle._scope.database, database) ||
        !_childLanes.contains(intent.entityType) || intent._denialUsed ||
        intent.ownerUid != ownerUid(handle)) {
      return const AccountFenceChildResult(accepted: false, parked: false, complete: false);
    }
    final settle = handle._session.reserveAccountFenceParking(handle._host,
        handle._scope, handle._capability, handle._ownerToken, handle._egressEpoch);
    intent._denialUsed = true;
    final ticket = AccountFenceChildParking._(intent, state);
    ({bool accepted, Future<bool> cleanup})? begun;
    var parked = false;
    try {
      begun = _beginAcceptance(handle, state, operationId: intent.operationId);
      if (begun.accepted) parked = await park(ticket);
    } catch (_) {
      // Accepted restriction is never rolled back on persistence/parking failure.
    } finally {
      ticket._settled = true;
      settle();
    }
    if (begun == null || !begun.accepted) {
      return const AccountFenceChildResult(accepted: false, parked: false, complete: false);
    }
    final complete = await begun.cleanup;
    return AccountFenceChildResult(accepted: true, parked: parked,
        complete: parked && complete);
  }

  Future<AccountFenceSmartInboxIntent?> captureSmartInboxIntent(
      AccountFenceHandle original, AppDatabase exactDB, {required String localId,
      required String serverId, required String status, required String editStamp}) async {
    if (localId.isEmpty || serverId.isEmpty || serverId.startsWith('local_capture:') ||
        !const {'open', 'resolved', 'dismissed'}.contains(status)) { return null; }
    DriftSmartInboxRepository.parseEditStamp(editStamp);
    final intent = await runCurrentLocal(original, exactDB, () => exactDB.transaction(() async {
      final row = await exactDB.customSelect(
        'SELECT 1 FROM smart_inbox_items WHERE id=${sqlString(localId)} '
        'AND server_id=${sqlString(serverId)} AND status=${sqlString(status)} '
        'AND pending_sync=1 AND updated_at=${sqlString(editStamp)};',
      ).getSingleOrNull();
      return row == null ? null : AccountFenceSmartInboxIntent._(original, exactDB,
          IdGenerator.uuidV4(), localId, serverId, status, editStamp);
    }));
    requireCurrentForDatabase(original, exactDB);
    return intent;
  }

  Future<AccountFenceResult> acceptSmartInboxDenial(AccountFenceHandle original,
      AppDatabase exactDB, AccountFenceSmartInboxIntent intent, AccountFenceState state) {
    if (!_current(original) || !identical(original, intent._handle) ||
        !identical(exactDB, intent._database) ||
        !identical(original._scope.database, exactDB) || intent._used) {
      return Future.value(const AccountFenceResult(accepted: false, complete: false));
    }
    intent._used = true;
    final begun = _beginAcceptance(original, state, operationId: intent._operationId);
    return begun.cleanup.then((complete) =>
        AccountFenceResult(accepted: begun.accepted, complete: complete));
  }

  Future<AccountFenceEngagementIntent?> captureEngagementIntent(
      AccountFenceHandle original, AppDatabase exactDB, {required String eventId,
      required String eventType, required String occurredAt,
      required String? businessKey, required int eventVersion}) async {
    if (eventId.isEmpty) return null;
    final intent = await runCurrentLocal(original, exactDB, () => exactDB.transaction(() async {
      final row = await exactDB.customSelect(
        'SELECT 1 FROM engagement_events WHERE event_id=${sqlString(eventId)} '
        'AND event_type=${sqlString(eventType)} AND occurred_at=${sqlString(occurredAt)} '
        'AND business_key IS ${sqlNullableString(businessKey)} '
        "AND event_version=$eventVersion AND status='pending';",
      ).getSingleOrNull();
      return row == null ? null : AccountFenceEngagementIntent._(original, exactDB,
          IdGenerator.uuidV4(), eventId, eventType, occurredAt, businessKey, eventVersion);
    }));
    requireCurrentForDatabase(original, exactDB);
    return intent;
  }

  Future<AccountFenceResult> acceptEngagementDenial(AccountFenceHandle original,
      AppDatabase exactDB, AccountFenceEngagementIntent intent, AccountFenceState state) {
    if (!_current(original) || !identical(original, intent._handle) ||
        !identical(exactDB, intent._database) ||
        !identical(original._scope.database, exactDB) || intent._used) {
      return Future.value(const AccountFenceResult(accepted: false, complete: false));
    }
    intent._used = true;
    final begun = _beginAcceptance(original, state, operationId: intent._operationId);
    return begun.cleanup.then((complete) =>
        AccountFenceResult(accepted: begun.accepted, complete: complete));
  }

  Future<AccountFenceSenderMappingIntent?> captureSenderMappingIntent(
      AccountFenceHandle original, AppDatabase exactDB, List<Map<String, Object?>> snapshots) async {
    if (snapshots.isEmpty || snapshots.any((row) => row['id'] is! String ||
        (row['id'] as String).isEmpty || row['normalized_sender_id'] is! String ||
        (row['normalized_sender_id'] as String).isEmpty)) {
      return null;
    }
    if (snapshots.map((row) => row['normalized_sender_id']).toSet().length != snapshots.length) return null;
    final intent = await runCurrentLocal(original, exactDB, () => exactDB.transaction(() async {
      for (final snapshot in snapshots) {
        final actual = await exactDB.customSelect('SELECT * FROM sender_bank_mappings '
            'WHERE id=${sqlString(snapshot['id'] as String)};').getSingleOrNull();
        if (actual == null || !mapEquals(actual.data, snapshot) ||
            !const {'pending', 'failed'}.contains(snapshot['sync_status']) ||
            snapshot['sync_permanent'] != 0 ||
            (snapshot['deleted_at'] == null && !const {'confirmed', 'rejected'}.contains(snapshot['status']))) {
          return null;
        }
      }
      return AccountFenceSenderMappingIntent._(original, exactDB, IdGenerator.uuidV4(), snapshots);
    }));
    requireCurrentForDatabase(original, exactDB);
    return intent;
  }

  Future<AccountFenceResult> acceptSenderMappingDenial(AccountFenceHandle original,
      AppDatabase exactDB, AccountFenceSenderMappingIntent intent, AccountFenceState state) {
    if (!_current(original) || !identical(original, intent._handle) ||
        !identical(exactDB, intent._database) ||
        !identical(original._scope.database, exactDB) || intent._used) {
      return Future.value(const AccountFenceResult(accepted: false, complete: false));
    }
    intent._used = true;
    final begun = _beginAcceptance(original, state, operationId: intent._operationId);
    return begun.cleanup.then((complete) => AccountFenceResult(accepted: begun.accepted, complete: complete));
  }

  Future<AccountFenceNotificationIntent?> captureNotificationIntent(
      AccountFenceHandle original, AppDatabase exactDB, Map<String, Object?> snapshot) async {
    final id = snapshot['id'];
    final logId = snapshot['notification_log_id'];
    if (id is! String || id.isEmpty || logId is! String || logId.isEmpty ||
        !const {'created', 'queued', 'sent', 'failed', 'opened'}.contains(snapshot['event_type']) ||
        snapshot['synced_at'] != null || snapshot['sync_attempt_count'] is! int ||
        (snapshot['sync_attempt_count'] as int) >= 8) { return null; }
    final dynamic payload;
    try { payload = jsonDecode(snapshot['payload_json'] as String); }
    catch (_) { return null; }
    if (payload is! Map || payload['_notification_origin'] is! Map ||
        payload['_notification_origin']['uid'] != ownerUid(original)) { return null; }
    final intent = await runCurrentLocal(original, exactDB, () => exactDB.transaction(() async {
      final actual = await exactDB.customSelect('SELECT * FROM notification_log_events '
          'WHERE id=${sqlString(id)};').getSingleOrNull();
      return actual != null && mapEquals(actual.data, snapshot)
          ? AccountFenceNotificationIntent._(original, exactDB, IdGenerator.uuidV4(), snapshot) : null;
    }));
    requireCurrentForDatabase(original, exactDB);
    return intent;
  }

  Future<AccountFenceResult> acceptNotificationDenial(AccountFenceHandle original,
      AppDatabase exactDB, AccountFenceNotificationIntent intent, AccountFenceState state) {
    if (!_current(original) || !identical(original, intent._handle) ||
        !identical(exactDB, intent._database) ||
        !identical(original._scope.database, exactDB) || intent._used) {
      return Future.value(const AccountFenceResult(accepted: false, complete: false));
    }
    intent._used = true;
    final begun = _beginAcceptance(original, state, operationId: intent._operationId);
    return begun.cleanup.then((complete) => AccountFenceResult(accepted: begun.accepted, complete: complete));
  }

  static const _activeDefaultSql =
      'SELECT * FROM accounts WHERE is_default = 1 AND deleted_at IS NULL;';

  /// Captures the CURRENT unique active default selection for the supplied
  /// ORIGINAL handle/database. The selection and its full row are read in one
  /// tracked local transaction; nothing here refreshes or retargets later.
  Future<AccountFenceDefaultAccountIntent?> captureDefaultAccountIntent(
      AccountFenceHandle original, AppDatabase exactDB,
      {required String localId, required String serverId}) async {
    if (localId.isEmpty || serverId.isEmpty) return null;
    final intent = await runCurrentLocal(original, exactDB, () => exactDB.transaction(() async {
      final active = await exactDB.customSelect(_activeDefaultSql).get();
      if (active.length != 1) return null;
      final row = active.single.data;
      if (row['id'] != localId || row['server_id'] != serverId) return null;
      return AccountFenceDefaultAccountIntent._(original, exactDB, IdGenerator.uuidV4(),
          localId, serverId, row);
    }));
    requireCurrentForDatabase(original, exactDB);
    return intent;
  }

  /// Semantic equality only: the same unique active default with an identical
  /// full row. An identical-state ABA is the SAME command. Reads only; callers
  /// run it inside their own tracked local transaction.
  Future<bool> defaultAccountIntentMatches(AccountFenceHandle original,
      AppDatabase exactDB, AccountFenceDefaultAccountIntent intent) async {
    if (!identical(original, intent._handle) || !identical(exactDB, intent._database) ||
        !identical(original._scope.database, exactDB) || intent._used) {
      return false;
    }
    final active = await exactDB.customSelect(_activeDefaultSql).get();
    return active.length == 1 && mapEquals(active.single.data, intent.snapshot);
  }

  Future<AccountFenceResult> acceptDefaultAccountDenial(AccountFenceHandle original,
      AppDatabase exactDB, AccountFenceDefaultAccountIntent intent, AccountFenceState state) {
    if (!_current(original) || !identical(original, intent._handle) ||
        !identical(exactDB, intent._database) ||
        !identical(original._scope.database, exactDB) || intent._used) {
      return Future.value(const AccountFenceResult(accepted: false, complete: false));
    }
    intent._used = true;
    final begun = _beginAcceptance(original, state, operationId: intent._operationId);
    return begun.cleanup.then((complete) => AccountFenceResult(accepted: begun.accepted, complete: complete));
  }

  static final _operationId = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  bool _current(AccountFenceHandle handle) =>
      identical(handle._authority, this) && identical(shared, this) &&
      handle._bindingEpoch == _bindingEpoch &&
      handle._egressEpoch == CloudEgressGate.instance.epoch &&
      identical(handle._host.current, handle._scope) &&
      handle._host.generation == handle._scope.generation &&
      handle._session.accountFenceCapturedLifetimeToken(handle._host, handle._scope,
          handle._capability) == handle._ownerToken &&
      store.holdFor(AccountFenceStore.ownerDigest(handle._scope.uid!)) == null;

  Future<AccountFenceResult> accept(AccountFenceHandle handle,
      AccountFenceState state, {required String operationId}) {
    final begun = _beginAcceptance(handle, state, operationId: operationId);
    return begun.cleanup.then((complete) =>
        AccountFenceResult(accepted: begun.accepted, complete: complete));
  }

  ({bool accepted, Future<bool> cleanup}) _beginAcceptance(AccountFenceHandle handle,
      AccountFenceState state, {required String operationId}) {
    if (!_current(handle)) {
      return (accepted: false, cleanup: Future.value(false));
    }
    final location = handle._scope.location!;
    final record = AccountFenceRecord(state: state, operationId: operationId,
        ownerGeneration: handle._ownerToken,
        replicaDigest: AccountFenceStore.replicaDigest(location.dbPath, location.keyName),
        scopeGeneration: handle._scope.generation);
    // No await/notification between entry validation, mirror, real retirement
    // and barrier registration. Already dispatched work is drained, not canceled.
    final persisted = store.record(AccountFenceStore.ownerDigest(handle._scope.uid!), record);
    final draining = handle._session.retireAccountFence(handle._host, handle._scope);
    _pendingCleanup++;
    final previous = _cleanup;
    final cleanup = previous.then((_) async {
      var closed = false;
      try {
        await draining;
        await handle._host.closeAccountFenceScope(handle._scope);
        closed = handle._scope.database.lifecycleState == DatabaseLifecycleState.closed;
      } catch (_) {
        _cleanupFailed = true;
      }
      final durable = await persisted;
      if (!durable || !closed) _cleanupFailed = true;
      _pendingCleanup--;
      return !_cleanupFailed;
    });
    _cleanup = cleanup;
    handle._session.publishAccountFenceRetirement();
    return (accepted: true, cleanup: cleanup);
  }

  /// Tests replace persistence, never decisions. Only detached/drained sessions
  /// may swap the whole real component. Restoring never revives prior handles.
  @visibleForTesting
  static void Function() replacePersistenceForTest({AccountFencePersistence? persistence}) {
    if (!AppSession.instance.accountFenceCanReplace || _shared._pendingCleanup != 0) {
      throw StateError('account_fence_test_replacement_requires_detached_session');
    }
    final previous = _shared;
    _bindingEpoch++;
    final installed = AccountFenceAuthority._(AccountFenceStore(persistence: persistence));
    _shared = installed;
    var restored = false;
    return () {
      if (restored || !identical(_shared, installed) ||
          !AppSession.instance.accountFenceCanReplace || _shared._pendingCleanup != 0) {
        throw StateError('account_fence_test_restore_requires_detached_session');
      }
      restored = true;
      _bindingEpoch++;
      _shared = previous;
    };
  }
}
