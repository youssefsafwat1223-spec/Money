import 'dart:async';

import 'package:flutter/services.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

/// ASR integration harness: a STATEFUL stand-in for the native side of the
/// ASR v7.2 successor protocol (one owner), reached through the real
/// [MethodChannel] the bridge uses. It mirrors the contract of
/// `SharedCaptureStore.swift` that the Dart side relies on:
///
///  * every protected write advances `egressMutationCounter` BEFORE its body
///    runs (also when the body then refuses); counter-bound transitions compare
///    the counter as it was before their own bump;
///  * the expiry revoke / `mintExpiryEvidenceForLiveOn` retire the lifetime and
///    mint expiry evidence; `inspectRecoveryEvidence` reports it;
///  * SE1 `publishRestrictiveCaptureOwner(successorOf)` consumes exactly that
///    evidence into a NEW owner generation G' (OFF, `successorOfExpiry`);
///  * SE2 begin / SE3 writeOn / SE4 finish are bound to the previous receipt's
///    counter; `retireSuccessor` and `inspectSuccessor` are exact to G'.
///
/// Both native layers always agree here (layer disagreement is covered by the
/// Swift XCTests). It is NOT native execution: nothing here proves the Swift
/// behaviour, only that the Dart production wiring drives this contract.
class AsrNativeSim {
  AsrNativeSim({required this.uid});

  final String uid;
  static final String uidHash = List.filled(64, 'a').join();

  // ── simulated native state ────────────────────────────────────────────────
  bool ownerAlive = false;
  int generation = 0;
  int lastGeneration = 0;
  int epoch = 0;
  int counter = 0;

  /// The owner's egress record (both layers), or null when absent.
  AsrEgressRecord? egress;

  /// The owner's pending-enable barrier (both layers), or null.
  Map<String, Object?>? pending;

  Map<String, Object?>? mirror;
  Map<String, Object?>? backendConfig;
  int _ids = 0;

  // ── observation and faults ────────────────────────────────────────────────
  final List<MethodCall> calls = [];

  /// Methods this sim does not model (answered with null).
  final List<String> unmodelled = [];

  /// Called with the method name at the start of every call.
  void Function(String method)? onCall;

  /// Called right after a call's state change applied, before the reply.
  void Function(String method)? afterApply;

  final Map<String, List<AsrSimFault>> _faults = {};
  final List<Completer<void>> _parked = [];

  void fault(String method, AsrSimFault f) => (_faults[method] ??= []).add(f);

  List<MethodCall> of(String method) =>
      calls.where((c) => c.method == method).toList();
  List<String> get methods => [for (final c in calls) c.method];

  /// Frees every call parked by [AsrSimFault.noReply] (their replies are then
  /// delivered to nobody that still waits).
  void releaseParked() {
    for (final c in _parked) {
      if (!c.isCompleted) c.complete();
    }
  }

  String _newId() => (++_ids).toRadixString(16).padLeft(32, 'c');

  /// Seeds a live, completed Cloud ON lifetime of [uid] (what a previous
  /// explicit enable left): owner [ownerGeneration]/[ownerEpoch], ON bound to it.
  void seedLiveOn({
    int ownerGeneration = 3,
    int ownerEpoch = 1,
    int transitionGeneration = 1,
    int reservedVersion = 1,
  }) {
    ownerAlive = true;
    generation = lastGeneration = ownerGeneration;
    epoch = ownerEpoch;
    egress = AsrEgressRecord(
        state: 'ON',
        transitionGeneration: transitionGeneration,
        reservedVersion: reservedVersion,
        lifeGeneration: ownerGeneration,
        lifeEpoch: ownerEpoch);
    mirror = {'uid': uid, 'cloud': true, 'ai': false};
  }

  // ── reply shapes ──────────────────────────────────────────────────────────
  static const _bindingKeys = [
    'operationId',
    'transitionGeneration',
    'reservedVersion',
    'ownerGeneration',
    'ownerEpoch'
  ];

  List<Map<String, Object?>> _barrier([String? cleared]) => [
        for (final layer in ['file', 'keychain'])
          if (cleared != null)
            {'layer': layer, 'outcome': cleared}
          else if (pending == null)
            {'layer': layer, 'outcome': 'absent'}
          else
            {'layer': layer, 'outcome': 'verified', ...pending!},
      ];

  List<Map<String, Object?>> _egress([String outcome = 'verified']) => [
        for (final layer in ['file', 'keychain'])
          if (egress == null)
            {'layer': layer, 'outcome': 'absent'}
          else
            _egressReport(layer, outcome, egress!),
      ];

  /// `SharedCaptureStore.egressReport`: a retired record reports its
  /// retirement's operation identity.
  static Map<String, Object?> _egressReport(
      String layer, String outcome, AsrEgressRecord e) {
    final r = e.retirement;
    final generation = r?['ownerGeneration'] ?? e.lifeGeneration;
    final epoch = r?['ownerEpoch'] ?? e.lifeEpoch;
    return {
      'layer': layer,
      'outcome': outcome,
      'state': e.state,
      'transitionGeneration': r?['transitionGeneration'] ?? e.transitionGeneration,
      'reservedVersion': r?['reservedVersion'] ?? e.reservedVersion,
      if (r != null) 'operationId': r['operationId'],
      if (generation != null) 'ownerGeneration': generation,
      if (epoch != null) 'ownerEpoch': epoch,
    };
  }

  Map<String, Object?> _reply(String operation, String status,
          {Map<String, Object?>? op,
          List<Map<String, Object?>>? barrier,
          List<Map<String, Object?>>? egressLayers,
          Map<String, Object?>? evidence,
          bool counted = false}) =>
      {
        'contractVersion': 1,
        'operation': operation,
        'status': status,
        if (op != null)
          for (final k in _bindingKeys) k: op[k],
        'barrier': barrier ?? _barrier(),
        'egress': egressLayers ?? _egress(),
        if (evidence != null) 'expiryEvidence': evidence,
        if (counted) 'mutationCounter': counter,
      };

  Map<String, Object?> _args(MethodCall c) =>
      c.arguments == null ? {} : Map<String, Object?>.from(c.arguments as Map);

  bool _live(int? g, int? e) => ownerAlive && g == generation && e == epoch;

  Map<String, Object?> _binding(Map<String, Object?> a) =>
      {for (final k in _bindingKeys) k: a[k]};

  bool _pendingIs(Map<String, Object?> a) =>
      pending != null && _bindingKeys.every((k) => pending![k] == a[k]);

  // ── the channel ───────────────────────────────────────────────────────────
  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    onCall?.call(call.method);
    final queue = _faults[call.method];
    final f = queue != null && queue.isNotEmpty ? queue.removeAt(0) : null;
    if (f == AsrSimFault.platformError) {
      if (NativeCaptureBridge.protectedNativeWrites.containsKey(call.method)) {
        counter++;
      }
      throw PlatformException(code: 'queue_unavailable');
    }
    if (f == AsrSimFault.noReplyBeforeApply) {
      final parked = Completer<void>();
      _parked.add(parked);
      await parked.future;
      throw PlatformException(code: 'parked');
    }
    final reply = _apply(call);
    afterApply?.call(call.method);
    if (f == AsrSimFault.noReply) {
      // Applied natively; the reply never arrives.
      final parked = Completer<void>();
      _parked.add(parked);
      await parked.future;
      throw PlatformException(code: 'parked');
    }
    if (f == AsrSimFault.lostReply) return null;
    return reply;
  }

  Object? _apply(MethodCall call) {
    final a = _args(call);
    if (NativeCaptureBridge.protectedNativeWrites.containsKey(call.method)) {
      // Counted transitions read `prior` before the bump.
      a['__prior'] = counter;
      counter++;
    }
    switch (call.method) {
      case 'captureOwnerEpoch':
        return epoch;
      case 'getCaptureOwner':
        return ownerAlive
            ? {'uid': uid, 'uidHash': uidHash, 'generation': generation}
            : null;
      case 'publishRestrictiveCaptureOwner':
        return _publishRestrictive(a);
      case 'revokeCaptureAuthorizationLifetime':
        return _revoke(a);
      case 'mintExpiryEvidenceForLiveOn':
        return _mint(a);
      case 'invalidateExpiryEvidence':
        final id = a['evidenceId'];
        if (egress?.evidence?['evidenceId'] == id) egress!.evidence = null;
        return _reply('invalidateExpiry', 'done',
            barrier: _barrier('absent'), counted: true);
      case 'inspectRecoveryEvidence':
        return _inspectEvidence();
      case 'confirmRecoveryEvidence':
        return counter == a['expectedCounter'];
      case 'beginCloudEgressEnable':
        return _begin(a);
      case 'writeCloudEgressEnableOn':
        return _writeOn(a);
      case 'restrictCloudEgressEnable':
        return _restrict(a);
      case 'finishCloudEgressEnable':
        return _finish(a);
      case 'retireSuccessor':
        return _retireSuccessor(a);
      case 'inspectSuccessor':
        return _inspectSuccessor(a);
      case 'getCloudEgressPending':
        return _reply('inspect', pending == null ? 'noBarrier' : 'pending',
            op: pending);
      case 'getCloudEgressState':
        final e = egress;
        if (e == null) return {'status': 'unset'};
        return {
          'status': 'record',
          'state': e.state,
          'ownerUid': uid,
          'transitionGeneration': e.transitionGeneration,
          'reservedVersion': e.reservedVersion,
        };
      case 'setCloudEgressState':
        return _setEgress(a);
      case 'setCaptureConsentMirror':
        mirror = a..remove('__prior');
        return null;
      case 'setCaptureBackendConfig':
        backendConfig = a;
        return null;
      case 'clearCaptureOwner':
        clearOwner();
        return true;
      default:
        unmodelled.add(call.method);
        return null;
    }
  }

  /// A native owner clear (logout / account switch): the epoch advances.
  void clearOwner() {
    ownerAlive = false;
    epoch++;
  }

  Object? _publishRestrictive(Map<String, Object?> a) {
    final prior = a['__prior'] as int;
    final version = a['version'] as int;
    final expectedEpoch = a['expectedEpoch'] as int;
    if (expectedEpoch != epoch) {
      throw PlatformException(code: 'owner_changed');
    }
    Map<String, Object?> refused(String status) => {
          'contractVersion': 1,
          'operation': 'publishRestrictive',
          'status': status,
          'barrier': _barrier('absent'),
          'egress': _egress(),
        };
    if (pending != null) return refused('conflict');
    if ((egress?.reservedVersion ?? 0) > version) return refused('stale');
    final successorId = a['successorEvidenceId'] as String?;
    if (successorId != null) {
      final e = egress;
      if (prior != a['successorExpectedCounter'] ||
          !ownerAlive ||
          e == null ||
          e.state != 'OFF' ||
          e.evidence?['evidenceId'] != successorId ||
          e.evidence?['ownerGeneration'] != generation ||
          e.evidence?['ownerEpoch'] != expectedEpoch) {
        return refused('conflict');
      }
    }
    final e = egress;
    final retired = e?.retirement != null;
    final unfinished = [
      e?.lifeGeneration ?? 0,
      (e?.retirement?['ownerGeneration'] as int?) ?? 0,
    ].reduce((x, y) => x > y ? x : y);
    final next = ownerAlive && !retired && unfinished <= generation
        ? generation
        : [lastGeneration, generation, unfinished]
                .reduce((x, y) => x > y ? x : y) +
            1;
    egress = AsrEgressRecord(
        state: 'OFF',
        transitionGeneration: e?.transitionGeneration ?? 0,
        reservedVersion: version,
        lifeGeneration: next,
        lifeEpoch: expectedEpoch,
        successorOf: successorId);
    generation = lastGeneration = next;
    ownerAlive = true;
    mirror = {'uid': uid, 'cloud': false, 'ai': false, 'version': version};
    return {
      'contractVersion': 1,
      'operation': 'publishRestrictive',
      'status': 'done',
      'owner': {'uid': uid, 'uidHash': uidHash, 'generation': next},
      'ownerGeneration': next,
      'ownerEpoch': expectedEpoch,
      'barrier': _barrier('absent'),
      'egress': _egress(),
      'mutationCounter': counter,
    };
  }

  Object? _revoke(Map<String, Object?> a) {
    final expected = _binding(a);
    if (!_live(a['ownerGeneration'] as int?, a['ownerEpoch'] as int?)) {
      return _reply('revoke', 'ownerMismatch', op: expected);
    }
    final e = egress;
    if (e != null) {
      if (e.retirement != null && !_same(e.retirement!, expected)) {
        return _reply('revoke', 'conflict', op: expected);
      }
      if (e.retirement == null &&
          ((e.lifeGeneration != null &&
                  e.lifeGeneration != a['ownerGeneration']) ||
              (e.lifeEpoch != null && e.lifeEpoch != a['ownerEpoch']))) {
        return _reply('revoke', 'stale', op: expected);
      }
    }
    final lifecycle = a['expirySessionLifecycle'] as int?;
    Map<String, Object?>? evidence;
    if (lifecycle != null && e != null) {
      final held = e.evidence;
      if (e.retirement != null &&
          _same(e.retirement!, expected) &&
          held != null &&
          held['sessionLifecycle'] == lifecycle) {
        return _reply('revoke', 'done',
            op: expected, evidence: held, counted: true);
      }
      if (e.state == 'ON' &&
          e.retirement == null &&
          e.lifeGeneration == a['ownerGeneration'] &&
          e.lifeEpoch == a['ownerEpoch'] &&
          pending == null) {
        evidence = {
          'evidenceId': _newId(),
          'ownerGeneration': a['ownerGeneration'],
          'ownerEpoch': a['ownerEpoch'],
          'sessionLifecycle': lifecycle,
        };
      }
    }
    int max(int x, int y) => x > y ? x : y;
    egress = AsrEgressRecord(
        state: 'OFF',
        transitionGeneration:
            max(e?.transitionGeneration ?? 0, a['transitionGeneration'] as int),
        reservedVersion:
            max(e?.reservedVersion ?? 0, a['reservedVersion'] as int),
        lifeGeneration: a['ownerGeneration'] as int,
        lifeEpoch: a['ownerEpoch'] as int,
        retirement: expected,
        evidence: evidence);
    return _reply('revoke', 'done',
        op: expected, evidence: evidence, counted: true);
  }

  Object? _mint(Map<String, Object?> a) {
    final prior = a['__prior'] as int;
    if (prior != a['expectedCounter']) return _reply('mintExpiry', 'conflict');
    if (!_live(a['ownerGeneration'] as int?, a['ownerEpoch'] as int?)) {
      return _reply('mintExpiry', 'ownerMismatch');
    }
    final e = egress;
    if (pending != null ||
        e == null ||
        e.state != 'ON' ||
        e.retirement != null ||
        e.transitionGeneration != a['transitionGeneration'] ||
        e.reservedVersion != a['reservedVersion'] ||
        e.lifeGeneration != a['ownerGeneration'] ||
        e.lifeEpoch != a['ownerEpoch']) {
      return _reply('mintExpiry', 'conflict');
    }
    final op = {
      'operationId': _newId(),
      'transitionGeneration': e.transitionGeneration,
      'reservedVersion': e.reservedVersion,
      'ownerGeneration': generation,
      'ownerEpoch': epoch,
    };
    final evidence = {
      'evidenceId': _newId(),
      'ownerGeneration': generation,
      'ownerEpoch': epoch,
      'sessionLifecycle': a['sessionLifecycle'],
    };
    egress = e.copy(state: 'OFF', retirement: op, evidence: evidence);
    return _reply('mintExpiry', 'done',
        op: op, evidence: evidence, counted: true);
  }

  Object? _inspectEvidence() {
    Map<String, Object?> snapshot(String kind,
            {bool owner = true, bool record = false}) =>
        {
          'kind': kind,
          if (owner) 'ownerGeneration': generation,
          if (owner) 'ownerEpoch': epoch,
          'mutationCounter': counter,
          if (record && egress != null) 'record': egress!.toRecord(),
        };
    if (!ownerAlive) return snapshot('none', owner: false);
    final e = egress;
    if (pending != null || e == null) return snapshot('none');
    final ev = e.evidence;
    if (e.state == 'OFF' &&
        e.retirement != null &&
        ev != null &&
        ev['ownerGeneration'] == generation &&
        ev['ownerEpoch'] == epoch) {
      return snapshot('expiryEvidence', record: true);
    }
    if (e.state == 'ON' &&
        e.retirement == null &&
        e.lifeGeneration == generation &&
        e.lifeEpoch == epoch) {
      return snapshot('liveOn', record: true);
    }
    return snapshot('none', record: true);
  }

  Object? _begin(Map<String, Object?> a) {
    final prior = a['__prior'] as int;
    final tg = a['transitionGeneration'] as int;
    final rv = a['reservedVersion'] as int;
    if (!ownerAlive) return _reply('begin', 'ownerMismatch');
    final successorId = a['successorEvidenceId'] as String?;
    if (successorId != null) {
      final e = egress;
      if (prior != a['successorExpectedCounter'] ||
          pending != null ||
          e == null ||
          e.state != 'OFF' ||
          e.successorOf != successorId ||
          e.retirement != null ||
          e.lifeGeneration != generation ||
          e.lifeEpoch != epoch ||
          e.reservedVersion > rv) {
        return _reply('begin', 'conflict');
      }
    }
    final resumeId = a['resumeOperationId'];
    if (pending != null) {
      if (resumeId == null ||
          pending!['operationId'] != resumeId ||
          pending!['transitionGeneration'] != tg ||
          pending!['reservedVersion'] != rv) {
        return _reply('begin', 'conflict', op: pending);
      }
    } else {
      if (resumeId != null) return _reply('begin', 'noBarrier');
      if ((egress?.transitionGeneration ?? -1) >= tg) {
        return _reply('begin', 'stale');
      }
      pending = {
        'operationId': _newId(),
        'transitionGeneration': tg,
        'reservedVersion': rv,
        'ownerGeneration': generation,
        'ownerEpoch': epoch,
      };
    }
    return _reply('begin', 'done', op: pending, counted: true);
  }

  Object? _writeOn(Map<String, Object?> a) {
    final prior = a['__prior'] as int;
    final expected = _binding(a);
    final want = a['expectedCounter'];
    if (want != null && prior != want) {
      return _reply('writeOn', 'conflict',
          op: expected, barrier: _barrier('absent'));
    }
    if (pending == null) return _reply('writeOn', 'noBarrier', op: expected);
    if (!_pendingIs(a)) return _reply('writeOn', 'conflict', op: expected);
    if (!_live(a['ownerGeneration'] as int?, a['ownerEpoch'] as int?)) {
      return _reply('writeOn', 'ownerMismatch', op: expected);
    }
    final e = egress;
    if (e != null &&
        (e.retirement != null ||
            (e.lifeGeneration != null &&
                e.lifeGeneration != a['ownerGeneration']) ||
            (e.lifeEpoch != null && e.lifeEpoch != a['ownerEpoch']))) {
      return _reply('writeOn', 'ownerMismatch', op: expected);
    }
    final tg = a['transitionGeneration'] as int;
    final rv = a['reservedVersion'] as int;
    if (e != null &&
        (e.transitionGeneration > tg ||
            e.reservedVersion > rv ||
            (e.transitionGeneration == tg && e.state != 'ON'))) {
      return _reply('writeOn', 'stale', op: expected);
    }
    egress = AsrEgressRecord(
        state: 'ON',
        transitionGeneration: tg,
        reservedVersion: rv,
        lifeGeneration: a['ownerGeneration'] as int,
        lifeEpoch: a['ownerEpoch'] as int,
        successorOf: e?.successorOf);
    return _reply('writeOn', 'done', op: expected, counted: true);
  }

  Object? _restrict(Map<String, Object?> a) {
    final expected = _binding(a);
    if (!_pendingIs(a)) return _reply('restrict', 'noBarrier', op: expected);
    final e = egress;
    var outcome = 'alreadyRestrictive';
    if (e != null &&
        e.state == 'ON' &&
        e.transitionGeneration == a['transitionGeneration']) {
      egress = e.copy(state: 'OFF');
      outcome = 'restricted';
    }
    return _reply('restrict', 'done',
        op: expected, egressLayers: _egress(outcome));
  }

  Object? _finish(Map<String, Object?> a) {
    final prior = a['__prior'] as int;
    final abandon = a['abandon'] == true;
    final name = abandon ? 'abandon' : 'complete';
    final expected = _binding(a);
    final want = a['expectedCounter'];
    if (want != null && prior != want) {
      return _reply(name, 'conflict',
          op: expected, barrier: _barrier('absent'));
    }
    if (!_pendingIs(a)) return _reply(name, 'noBarrier', op: expected);
    if (abandon) {
      if (egress?.state == 'ON') return _reply(name, 'conflict', op: expected);
      pending = null;
      return _reply(name, 'done', op: expected, barrier: _barrier('cleared'));
    }
    if (!_live(a['ownerGeneration'] as int?, a['ownerEpoch'] as int?)) {
      return _reply(name, 'ownerMismatch', op: expected);
    }
    final e = egress;
    if (e == null ||
        e.state != 'ON' ||
        e.transitionGeneration != a['transitionGeneration'] ||
        e.reservedVersion != a['reservedVersion']) {
      return _reply(name, 'conflict', op: expected);
    }
    pending = null;
    return _reply(name, 'done',
        op: expected, barrier: _barrier('cleared'), counted: true);
  }

  Object? _retireSuccessor(Map<String, Object?> a) {
    final sg = a['successorGeneration'] as int;
    final e0 = a['ownerEpoch'] as int;
    final id = a['operationId'] as String;
    final e = egress;
    if (!_live(sg, e0) ||
        (e != null && (e.lifeGeneration != sg || e.lifeEpoch != e0))) {
      return _reply('retireSuccessor', 'stale');
    }
    final own = pending?['operationId'] == id ? pending : null;
    final op = own ??
        {
          'operationId': id,
          'transitionGeneration': e?.transitionGeneration ?? 0,
          'reservedVersion': e?.reservedVersion ?? 0,
          'ownerGeneration': sg,
          'ownerEpoch': e0,
        };
    egress = AsrEgressRecord(
        state: 'OFF',
        transitionGeneration: op['transitionGeneration'] as int,
        reservedVersion: op['reservedVersion'] as int,
        lifeGeneration: sg,
        lifeEpoch: e0,
        retirement: op);
    if (own != null) pending = null;
    return _reply('retireSuccessor', 'done', op: op);
  }

  Object? _inspectSuccessor(Map<String, Object?> a) {
    final sg = a['successorGeneration'] as int;
    final e0 = a['ownerEpoch'] as int;
    final e = egress;
    if (!_live(sg, e0) ||
        e == null ||
        e.state != 'ON' ||
        e.retirement != null ||
        e.lifeGeneration != sg ||
        e.lifeEpoch != e0) {
      return 'other';
    }
    if (pending == null) return 'finished';
    if (pending!['operationId'] == a['operationId']) return 'behindBarrier';
    return 'other';
  }

  Object? _setEgress(Map<String, Object?> a) {
    final state = a['state'] as String;
    final e = egress;
    if (state == 'ON' &&
        (pending != null ||
            e?.retirement != null ||
            e?.lifeGeneration != null)) {
      throw PlatformException(code: 'egress_denied');
    }
    final tg = a['transitionGeneration'] as int;
    if (e != null && tg < e.transitionGeneration) {
      throw PlatformException(code: 'stale_generation');
    }
    egress = e == null
        ? AsrEgressRecord(
            state: state,
            transitionGeneration: tg,
            reservedVersion: a['reservedVersion'] as int)
        : e.copy(state: state, transitionGeneration: tg);
    return null;
  }

  static bool _same(Map<String, Object?> x, Map<String, Object?> y) =>
      _bindingKeys.every((k) => x[k] == y[k]);
}

enum AsrSimFault {
  /// The call throws (native storage unavailable); counted when protected.
  platformError,

  /// Native applies the call but its reply never arrives.
  noReply,

  /// The call never reaches native execution and never replies.
  noReplyBeforeApply,

  /// Native applies the call; the reply is lost (null).
  lostReply,
}

class AsrEgressRecord {
  AsrEgressRecord({
    required this.state,
    required this.transitionGeneration,
    required this.reservedVersion,
    this.lifeGeneration,
    this.lifeEpoch,
    this.retirement,
    this.evidence,
    this.successorOf,
  });

  String state;
  int transitionGeneration;
  int reservedVersion;
  int? lifeGeneration;
  int? lifeEpoch;
  Map<String, Object?>? retirement;
  Map<String, Object?>? evidence;
  String? successorOf;

  AsrEgressRecord copy({
    String? state,
    int? transitionGeneration,
    Map<String, Object?>? retirement,
    Map<String, Object?>? evidence,
  }) =>
      AsrEgressRecord(
          state: state ?? this.state,
          transitionGeneration:
              transitionGeneration ?? this.transitionGeneration,
          reservedVersion: reservedVersion,
          lifeGeneration: lifeGeneration,
          lifeEpoch: lifeEpoch,
          retirement: retirement ?? this.retirement,
          evidence: evidence ?? this.evidence,
          successorOf: successorOf);

  Map<String, Object?> toRecord() => {
        'state': state,
        'transitionGeneration': transitionGeneration,
        'reservedVersion': reservedVersion,
        if (lifeGeneration != null) 'lifetimeOwnerGeneration': lifeGeneration,
        if (lifeEpoch != null) 'lifetimeOwnerEpoch': lifeEpoch,
        if (evidence != null) 'expiryEvidence': evidence,
      };
}

/// The capture queue bridge over the same simulated native owner (bootstrap's
/// owner clear / epoch reads hit the sim, so logout advances its epoch).
class AsrSimQueue implements CaptureQueueBridge {
  AsrSimQueue(this.sim);
  final AsrNativeSim sim;

  @override
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier() async =>
      const CaptureRemovalBarrierRead.absent();
  @override
  Future<void> beginCaptureRemoval(String uid) async => sim.counter++;
  @override
  Future<void> finishCaptureRemoval(String uid) async => sim.counter++;
  @override
  Future<int> captureOwnerEpoch() async => sim.epoch;
  @override
  Future<bool> clearCaptureOwner({bool clearHint = false}) async {
    sim.counter++;
    sim.clearOwner();
    return true;
  }

  @override
  Future<void> publishCaptureOwner({
    required String uid,
    required bool cloud,
    required bool ai,
    required int version,
    required int expectedEpoch,
    int? transitionGeneration,
  }) async {
    sim.counter++;
    if (expectedEpoch != sim.epoch) throw StateError('owner_changed');
    sim.ownerAlive = true;
    sim.mirror = {'uid': uid, 'cloud': cloud, 'ai': ai, 'version': version};
  }
}
