import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Session;

/// ASR design v7.2 §6.2 — the one session item `qirsh.session.v2.<nsHash>`.
///
/// Parsing is strict: anything the codec does not fully understand (unknown
/// version, missing or extra required fields, a checksum mismatch, a session the
/// SDK would not accept) throws [FormatException], which the store classifies as
/// unknown provenance (restrictive). There is no fallback and no partial record.

enum RecordKind { session, tombstone }

enum CredentialState { live, dead }

/// v7.1 V3: whether the credential may be admitted by ordinary automatic
/// reconciliation. Only ASR consumes [requiresAdoption].
enum AdmissionDisposition { ordinary, requiresAdoption }

/// §10.3 durable refresh-op states.
enum RefreshOpState { reserved, dispatchMarked, retryable, exhausted }

enum AdoptionState { pending, finalizing, failed }

/// §7.5.1 native-finish progress inside `finalizing`.
enum FinishState { awaiting, dispatched, confirmed }

String _canonicalJson(Object? value) => jsonEncode(_sortKeys(value));

Object? _sortKeys(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k as String).toList()..sort();
    return {for (final k in keys) k: _sortKeys(value[k])};
  }
  if (value is List) return value.map(_sortKeys).toList();
  return value;
}

/// SHA-256 hex of a string.
String sha256Hex(String s) => sha256.convert(utf8.encode(s)).toString();

/// The canonical form of a session: `jsonEncode(sortKeys(Session.fromJson(x)
/// .toJson()))`. Throws [FormatException] when the SDK would not accept it.
String canonicalSession(Map<String, dynamic> json) {
  final Session? session;
  try {
    session = Session.fromJson(json);
  } catch (_) {
    throw const FormatException('session_not_accepted');
  }
  if (session == null || session.expiresAt == null) {
    throw const FormatException('session_not_accepted');
  }
  return _canonicalJson(session.toJson());
}

/// Digest of a canonical session (what every "SDK digest == committed digest"
/// comparison uses). Null session → the empty digest `∅`.
String sessionDigest(Session? session) =>
    session == null ? emptyDigest : sha256Hex(_canonicalJson(session.toJson()));

const String emptyDigest = '∅';

/// The canonical configured origin's namespace hash (`ns`): scheme, host, port,
/// base path.
String namespaceHash(Uri origin) {
  final port = origin.hasPort
      ? origin.port
      : (origin.scheme == 'https' ? 443 : (origin.scheme == 'http' ? 80 : 0));
  var path = origin.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return sha256Hex(
      '${origin.scheme.toLowerCase()}://${origin.host.toLowerCase()}:$port$path');
}

String sessionItemKey(String ns) => 'qirsh.session.v2.$ns';

@immutable
class RefreshOpRecord {
  const RefreshOpRecord({
    required this.opId,
    required this.lifecycle,
    required this.tokenDigest,
    required this.state,
    required this.expectedSeq,
  });

  final String opId;
  final int lifecycle;
  final String tokenDigest;
  final RefreshOpState state;
  final int expectedSeq;

  RefreshOpRecord copyWith({RefreshOpState? state, int? expectedSeq}) =>
      RefreshOpRecord(
        opId: opId,
        lifecycle: lifecycle,
        tokenDigest: tokenDigest,
        state: state ?? this.state,
        expectedSeq: expectedSeq ?? this.expectedSeq,
      );

  Map<String, Object?> toJson() => {
        'opId': opId,
        'lifecycle': lifecycle,
        'tokenDigest': tokenDigest,
        'state': state.name,
        'expectedSeq': expectedSeq,
      };

  static RefreshOpRecord fromJson(Object? j) {
    final m = _map(j, const {'opId', 'lifecycle', 'tokenDigest', 'state', 'expectedSeq'});
    return RefreshOpRecord(
      opId: _str(m['opId']),
      lifecycle: _int(m['lifecycle']),
      tokenDigest: _str(m['tokenDigest']),
      state: _enum(RefreshOpState.values, m['state']),
      expectedSeq: _int(m['expectedSeq']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RefreshOpRecord &&
      other.opId == opId &&
      other.lifecycle == lifecycle &&
      other.tokenDigest == tokenDigest &&
      other.state == state &&
      other.expectedSeq == expectedSeq;

  @override
  int get hashCode => Object.hash(opId, lifecycle, tokenDigest, state, expectedSeq);
}

/// Durable dispatch count for ONE token digest (§10.5).
@immutable
class TokenDispatches {
  const TokenDispatches({required this.digest, required this.count});
  final String digest;
  final int count;

  Map<String, Object?> toJson() => {'digest': digest, 'count': count};

  static TokenDispatches fromJson(Object? j) {
    final m = _map(j, const {'digest', 'count'});
    final count = _int(m['count']);
    if (count < 0) throw const FormatException('count');
    return TokenDispatches(digest: _str(m['digest']), count: count);
  }

  @override
  bool operator ==(Object other) =>
      other is TokenDispatches && other.digest == digest && other.count == count;
  @override
  int get hashCode => Object.hash(digest, count);
}

@immutable
class SuccessorRecord {
  const SuccessorRecord({
    required this.generation,
    required this.evidenceId,
    required this.pendingOpId,
    required this.finish,
  });

  final int generation;
  final String evidenceId;
  final String pendingOpId;
  final FinishState finish;

  SuccessorRecord withFinish(FinishState f) => SuccessorRecord(
      generation: generation,
      evidenceId: evidenceId,
      pendingOpId: pendingOpId,
      finish: f);

  Map<String, Object?> toJson() => {
        'generation': generation,
        'evidenceId': evidenceId,
        'pendingOpId': pendingOpId,
        'finish': finish.name,
      };

  static SuccessorRecord fromJson(Object? j) {
    final m = _map(j, const {'generation', 'evidenceId', 'pendingOpId', 'finish'});
    return SuccessorRecord(
      generation: _int(m['generation']),
      evidenceId: _str(m['evidenceId']),
      pendingOpId: _str(m['pendingOpId']),
      finish: _enum(FinishState.values, m['finish']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SuccessorRecord &&
      other.generation == generation &&
      other.evidenceId == evidenceId &&
      other.pendingOpId == pendingOpId &&
      other.finish == finish;
  @override
  int get hashCode => Object.hash(generation, evidenceId, pendingOpId, finish);
}

@immutable
class AdoptionRecord {
  const AdoptionRecord({
    required this.state,
    required this.lifecycle,
    required this.opId,
    this.successor,
  });

  final AdoptionState state;
  final int lifecycle;
  final String opId;
  final SuccessorRecord? successor;

  Map<String, Object?> toJson() => {
        'state': state.name,
        'lifecycle': lifecycle,
        'opId': opId,
        if (successor != null) 'successor': successor!.toJson(),
      };

  static AdoptionRecord fromJson(Object? j) {
    final m = _map(j, const {'state', 'lifecycle', 'opId'},
        optional: const {'successor'});
    final state = _enum(AdoptionState.values, m['state']);
    final successor =
        m.containsKey('successor') ? SuccessorRecord.fromJson(m['successor']) : null;
    if (successor != null && state != AdoptionState.finalizing) {
      throw const FormatException('successor_outside_finalizing');
    }
    return AdoptionRecord(
      state: state,
      lifecycle: _int(m['lifecycle']),
      opId: _str(m['opId']),
      successor: successor,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AdoptionRecord &&
      other.state == state &&
      other.lifecycle == lifecycle &&
      other.opId == opId &&
      other.successor == successor;
  @override
  int get hashCode => Object.hash(state, lifecycle, opId, successor);
}

/// The record. Use [copyWith] to derive the next write; [encode] computes the
/// checksum.
@immutable
class SessionRecord {
  const SessionRecord({
    required this.ns,
    required this.installId,
    required this.seq,
    required this.lifecycle,
    required this.kind,
    this.owner,
    this.session,
    this.credential = CredentialState.live,
    this.admission = AdmissionDisposition.requiresAdoption,
    this.refreshOp,
    this.tokenDispatches,
    this.adoption,
    this.autoAdmissionBlocked,
  });

  static const int version = 2;

  final String ns;
  final String installId;
  final int seq;
  final int lifecycle;
  final RecordKind kind;
  final String? owner;

  /// The canonical session JSON (already passed through [canonicalSession]).
  final String? session;
  final CredentialState credential;
  final AdmissionDisposition admission;
  final RefreshOpRecord? refreshOp;
  final TokenDispatches? tokenDispatches;
  final AdoptionRecord? adoption;
  final int? autoAdmissionBlocked;

  /// Digest of [session] (`∅` for none).
  String get digest => session == null ? emptyDigest : sha256Hex(session!);

  Session? get sdkSession {
    final s = session;
    if (s == null) return null;
    return Session.fromJson(jsonDecode(s) as Map<String, dynamic>);
  }

  bool get isTombstone => kind == RecordKind.tombstone;

  SessionRecord copyWith({
    int? seq,
    int? lifecycle,
    RecordKind? kind,
    String? owner,
    String? session,
    CredentialState? credential,
    AdmissionDisposition? admission,
    RefreshOpRecord? Function()? refreshOp,
    TokenDispatches? Function()? tokenDispatches,
    AdoptionRecord? Function()? adoption,
    int? Function()? autoAdmissionBlocked,
  }) =>
      SessionRecord(
        ns: ns,
        installId: installId,
        seq: seq ?? this.seq,
        lifecycle: lifecycle ?? this.lifecycle,
        kind: kind ?? this.kind,
        owner: owner ?? this.owner,
        session: session ?? this.session,
        credential: credential ?? this.credential,
        admission: admission ?? this.admission,
        refreshOp: refreshOp != null ? refreshOp() : this.refreshOp,
        tokenDispatches:
            tokenDispatches != null ? tokenDispatches() : this.tokenDispatches,
        adoption: adoption != null ? adoption() : this.adoption,
        autoAdmissionBlocked: autoAdmissionBlocked != null
            ? autoAdmissionBlocked()
            : this.autoAdmissionBlocked,
      );

  /// A tombstone (§6.4-3).
  SessionRecord tombstone() => SessionRecord(
        ns: ns,
        installId: installId,
        seq: seq + 1,
        lifecycle: lifecycle + 1,
        kind: RecordKind.tombstone,
      );

  Map<String, Object?> _body() => {
        'v': version,
        'ns': ns,
        'installId': installId,
        'seq': seq,
        'lifecycle': lifecycle,
        'kind': kind.name,
        if (owner != null) 'owner': owner,
        if (session != null) 'session': session,
        'credential': credential.name,
        'admission': admission.name,
        if (refreshOp != null) 'refreshOp': refreshOp!.toJson(),
        if (tokenDispatches != null) 'tokenDispatches': tokenDispatches!.toJson(),
        if (adoption != null) 'adoption': adoption!.toJson(),
        if (autoAdmissionBlocked != null)
          'autoAdmissionBlocked': autoAdmissionBlocked,
      };

  String encode() {
    _validate(this);
    final body = _body();
    final checksum = sha256Hex(_canonicalJson(body));
    return _canonicalJson({...body, 'checksum': checksum});
  }

  static SessionRecord decode(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('json');
    }
    if (decoded is! Map) throw const FormatException('not_object');
    final m = Map<String, Object?>.from(decoded);
    final checksum = m.remove('checksum');
    if (checksum is! String) throw const FormatException('checksum_missing');
    if (sha256Hex(_canonicalJson(m)) != checksum) {
      throw const FormatException('checksum');
    }
    final r = _map(m, const {'v', 'ns', 'installId', 'seq', 'lifecycle', 'kind', 'credential'},
        optional: const {
          'owner', 'session', 'admission', 'refreshOp', 'tokenDispatches',
          'adoption', 'autoAdmissionBlocked',
        });
    if (r['v'] != version) throw const FormatException('version');
    final session = r['session'];
    String? canonical;
    if (session != null) {
      final s = _str(session);
      final Object? sj = jsonDecode(s);
      if (sj is! Map<String, dynamic>) throw const FormatException('session');
      canonical = canonicalSession(sj);
      if (canonical != s) throw const FormatException('session_not_canonical');
    }
    final record = SessionRecord(
      ns: _str(r['ns']),
      installId: _str(r['installId']),
      seq: _int(r['seq']),
      lifecycle: _int(r['lifecycle']),
      kind: _enum(RecordKind.values, r['kind']),
      owner: r['owner'] == null ? null : _str(r['owner']),
      session: canonical,
      credential: _enum(CredentialState.values, r['credential']),
      // A record without `admission` (none exist before v7.1; defensive) is
      // read as requiresAdoption.
      admission: r['admission'] == null
          ? AdmissionDisposition.requiresAdoption
          : _enum(AdmissionDisposition.values, r['admission']),
      refreshOp: r['refreshOp'] == null ? null : RefreshOpRecord.fromJson(r['refreshOp']),
      tokenDispatches: r['tokenDispatches'] == null
          ? null
          : TokenDispatches.fromJson(r['tokenDispatches']),
      adoption: r['adoption'] == null ? null : AdoptionRecord.fromJson(r['adoption']),
      autoAdmissionBlocked: r['autoAdmissionBlocked'] == null
          ? null
          : _int(r['autoAdmissionBlocked']),
    );
    _validate(record);
    return record;
  }

  static void _validate(SessionRecord r) {
    if (r.seq < 0 || r.lifecycle < 0) throw const FormatException('negative');
    if (r.kind == RecordKind.tombstone) {
      if (r.owner != null || r.session != null || r.refreshOp != null ||
          r.adoption != null) {
        throw const FormatException('tombstone_payload');
      }
    } else {
      if (r.owner == null || r.session == null) {
        throw const FormatException('session_payload');
      }
      final s = r.sdkSession;
      if (s == null || s.user.id != r.owner) {
        throw const FormatException('owner_mismatch');
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SessionRecord && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;
}

// ------------------------------------------------------------------ helpers

Map<String, Object?> _map(Object? j, Set<String> required,
    {Set<String> optional = const {}}) {
  if (j is! Map) throw const FormatException('not_object');
  final m = Map<String, Object?>.from(j);
  for (final k in required) {
    if (!m.containsKey(k)) throw FormatException('missing_$k');
  }
  for (final k in m.keys) {
    if (!required.contains(k) && !optional.contains(k)) {
      throw FormatException('unknown_$k');
    }
  }
  return m;
}

String _str(Object? v) {
  if (v is! String || v.isEmpty) throw const FormatException('string');
  return v;
}

int _int(Object? v) {
  if (v is! int) throw const FormatException('int');
  return v;
}

T _enum<T extends Enum>(List<T> values, Object? v) {
  for (final e in values) {
    if (e.name == v) return e;
  }
  throw const FormatException('enum');
}
