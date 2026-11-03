import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/session_record.dart';

import 'session_fixtures.dart';

/// ASR v7.2 §6.2: record codec — canonical form, checksum, strict parsing
/// (anything unexpected is unknown provenance), and the v7.1 admission field.
void main() {
  SessionRecord record({AdmissionDisposition? admission}) => SessionRecord(
        ns: 'ns1',
        installId: 'inst1',
        seq: 3,
        lifecycle: 2,
        kind: RecordKind.session,
        owner: 'user-a',
        session: canonicalSession(sessionJson(uid: 'user-a', exp: 2000000000)),
        admission: admission ?? AdmissionDisposition.ordinary,
        refreshOp: const RefreshOpRecord(
            opId: 'op1',
            lifecycle: 2,
            tokenDigest: 'd',
            state: RefreshOpState.dispatchMarked,
            expectedSeq: 3),
        tokenDispatches: const TokenDispatches(digest: 'd', count: 1),
        adoption: const AdoptionRecord(
          state: AdoptionState.finalizing,
          lifecycle: 2,
          opId: 'op1',
          successor: SuccessorRecord(
              generation: 7,
              evidenceId: 'ev',
              pendingOpId: 'p',
              finish: FinishState.dispatched),
        ),
      );

  test('round trip is exact and canonical', () {
    final r = record();
    final raw = r.encode();
    final back = SessionRecord.decode(raw);
    expect(back.encode(), raw);
    expect(back.adoption!.successor!.finish, FinishState.dispatched);
    expect(back.admission, AdmissionDisposition.ordinary);
    expect(back.sdkSession!.user.id, 'user-a');
  });

  test('canonical session is idempotent and digest is stable', () {
    final c1 = canonicalSession(sessionJson(uid: 'u', exp: 2000000000));
    final c2 = canonicalSession(jsonDecode(c1) as Map<String, dynamic>);
    expect(c2, c1);
    final r = record();
    expect(sessionDigest(r.sdkSession), r.digest);
    expect(sessionDigest(null), emptyDigest);
  });

  test('checksum mismatch → FormatException', () {
    final m = jsonDecode(record().encode()) as Map<String, dynamic>;
    m['seq'] = 4;
    expect(() => SessionRecord.decode(jsonEncode(m)), throwsFormatException);
  });

  String reseal(Map<String, dynamic> m) {
    m.remove('checksum');
    final keys = m.keys.toList()..sort();
    final body = {for (final k in keys) k: m[k]};
    return jsonEncode({...body, 'checksum': sha256Hex(jsonEncode(_sorted(body)))});
  }

  test('unknown field, unknown version, malformed JSON → FormatException', () {
    final m = jsonDecode(record().encode()) as Map<String, dynamic>;
    expect(() => SessionRecord.decode(reseal({...m, 'extra': 1})),
        throwsFormatException);
    expect(() => SessionRecord.decode(reseal({...m, 'v': 3})),
        throwsFormatException);
    expect(() => SessionRecord.decode('{'), throwsFormatException);
    expect(() => SessionRecord.decode('[]'), throwsFormatException);
  });

  test('owner must match the session user', () {
    final m = jsonDecode(record().encode()) as Map<String, dynamic>;
    expect(() => SessionRecord.decode(reseal({...m, 'owner': 'user-b'})),
        throwsFormatException);
  });

  test('a session the SDK would not accept is rejected', () {
    expect(() => canonicalSession({'access_token': 'x'}), throwsFormatException);
    expect(() => canonicalSession({}), throwsFormatException);
  });

  test('missing admission reads as requiresAdoption (defensive)', () {
    final m = jsonDecode(record().encode()) as Map<String, dynamic>
      ..remove('admission');
    expect(SessionRecord.decode(reseal(m)).admission,
        AdmissionDisposition.requiresAdoption);
  });

  test('tombstone carries no payload', () {
    final t = record().tombstone();
    expect(t.seq, 4);
    expect(t.lifecycle, 3);
    final back = SessionRecord.decode(t.encode());
    expect(back.isTombstone, isTrue);
    expect(back.session, isNull);
  });

  test('successor outside finalizing is malformed', () {
    final m = jsonDecode(record().encode()) as Map<String, dynamic>;
    (m['adoption'] as Map)['state'] = 'pending';
    expect(() => SessionRecord.decode(reseal(m)), throwsFormatException);
  });

  test('namespace hash canonicalizes the origin', () {
    expect(namespaceHash(Uri.parse('https://X.supabase.co/')),
        namespaceHash(Uri.parse('https://x.supabase.co:443')));
    expect(namespaceHash(Uri.parse('https://x.supabase.co')),
        isNot(namespaceHash(Uri.parse('https://y.supabase.co'))));
  });
}

Object? _sorted(Object? v) {
  if (v is Map) {
    final keys = v.keys.cast<String>().toList()..sort();
    return {for (final k in keys) k: _sorted(v[k])};
  }
  if (v is List) return v.map(_sorted).toList();
  return v;
}
