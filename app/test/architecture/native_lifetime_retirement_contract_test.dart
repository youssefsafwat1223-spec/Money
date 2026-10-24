import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Astra A1 / §2b static pins (Swift cannot run here; the behavioural proof is
/// ios/RunnerTests/RunnerTests.swift "Lifetime retirement" cases, which need an
/// approved isolated native harness).
String _body(String source, String signature) {
  final at = source.indexOf(signature);
  if (at < 0) throw StateError('$signature not found');
  final open = source.indexOf('{', at + signature.length);
  if (open < 0) throw StateError('no body after $signature');
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) return source.substring(open, i + 1);
  }
  throw StateError('unbalanced braces after $signature');
}

void main() {
  late String store;
  late String copy;
  late String revoke;
  late String denied;

  setUpAll(() {
    store = File('ios/Runner/SharedCaptureStore.swift').readAsStringSync();
    copy = File('ios/ShareBankMessage/SharedCaptureStore.swift').readAsStringSync();
    revoke = _body(store, 'static func revokeCaptureAuthorizationLifetime(');
    denied = _body(store, 'private static func egressDenied(forOwner owner: String?)');
  });

  test('both store copies are byte-identical', () {
    expect(copy, store);
  });

  group('A1 generation-covering retirement', () {
    test('a newer enable transition of the SAME lifecycle is never "stale"', () {
      expect(revoke, isNot(contains('entry.transitionGeneration > transitionGeneration')),
          reason: 'publication gen g, enable gen g+1 must still be retired');
    });

    test('a different owner generation/epoch is still stale and untouched', () {
      expect(revoke, contains('entry.lifetimeOwnerGeneration.map({ \$0 != ownerGeneration }) == true'));
      expect(revoke, contains('entry.lifetimeOwnerEpoch.map({ \$0 != ownerEpoch }) == true'));
      expect(revoke, contains('guard let active = try readActiveOwner(), active.uid == owner,'));
      expect(revoke, contains('active.generation == ownerGeneration'));
      expect(revoke, contains('snapshotCounter(ownerEpochKey, in: defaults) == ownerEpoch'));
    });

    test('retirement keeps the highest transition generation and verified receipts', () {
      expect(revoke, contains('max(old?.transitionGeneration ?? 0, transitionGeneration)'));
      expect(revoke, contains('retirement: expected'));
      expect(revoke, contains('reports.allSatisfy { \$0.outcome == .verified } ? .done : .incomplete'));
      expect(revoke, contains('return try withQueueLock {'));
    });
  });

  group('§2b bound-record admission', () {
    test('egressDenied requires the same normalized uid/hash and valid generation', () {
      expect(denied, contains('active.uid == normalizedUID(owner)'));
      expect(denied, contains('active.uidHash == hash'));
      expect(denied, contains('active.generation > 0'));
      expect(denied, contains('snapshotCounter(ownerGenerationKey, in: defaults) == active.generation'));
    });

    test('the documented all-legacy behaviour is retained', () {
      expect(denied, contains('mine.count == 2 && mine[0] != mine[1]'));
      expect(denied, contains('lifetimeOwnerGeneration != nil || \$0.lifetimeOwnerEpoch != nil'));
    });
  });
}
