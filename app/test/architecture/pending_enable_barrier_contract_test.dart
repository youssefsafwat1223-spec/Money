import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Consent-security amendment (native subunit): static pins on the source
/// properties that make the pending-enable barrier safe, so a regression fails in
/// Linux CI. Swift cannot run here; the behavioural proof is ios/RunnerTests/
/// RunnerTests.swift ("Pending enable barrier", needs Xcode). Style follows
/// cloud_egress_swift_g3_contract_test.dart.
/// The brace-matched body of the function that starts at [signature]. Parsing
/// problems are descriptive [StateError]s, never `expect`: this runs from
/// `setUpAll` (a valid test zone) and from test bodies only.
String _body(String source, String signature) {
  final at = source.indexOf(signature);
  if (at < 0) throw StateError('$signature not found');
  final open = source.indexOf('{', at + signature.length);
  if (open < 0) throw StateError('no body after $signature');
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) {
      return source.substring(open, i + 1);
    }
  }
  throw StateError('unbalanced braces after $signature');
}

void main() {
  // Nothing is read or parsed while the tests are being REGISTERED: a missing
  // file or marker must fail inside setUpAll, with its own message.
  late String store;
  late String copy;
  late String appDelegate;
  late String begin;
  late String writeOn;
  late String restrict;
  late String finish;
  late String section;
  late String restrictivePublication;

  String body(String source, String signature) => _body(source, signature);

  setUpAll(() {
    store = File('ios/Runner/SharedCaptureStore.swift').readAsStringSync();
    copy = File('ios/ShareBankMessage/SharedCaptureStore.swift')
        .readAsStringSync();
    appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    begin = body(store, 'static func beginCloudEgressEnable(');
    writeOn = body(store, 'static func writeCloudEgressEnableOn(');
    restrict = body(store, 'static func restrictCloudEgressEnable(');
    finish = body(store, 'static func finishCloudEgressEnable(');
    final from = store.indexOf('// MARK: Pending enable barrier');
    final to = store.indexOf('// MARK: Native in-flight registry');
    if (from < 0 || to < from) {
      throw StateError('pending-enable section markers not found');
    }
    restrictivePublication = body(store, 'static func publishRestrictiveCaptureOwner(');
    // N's separate restrictive owner publication is not an enable phase. Keep
    // every helper/phase assertion, excluding only its brace-matched body.
    section = store.substring(from, to).replaceFirst(restrictivePublication, '');
  });

  test('the two SharedCaptureStore copies stay byte-identical', () {
    expect(copy, store);
  });

  test('the barrier is a Keychain item plus an App Group file, flock-only', () {
    expect(store, contains('"cloud_egress_pending_v1"'));
    expect(store, contains('"cloud_egress_pending_v1.json"'));
    for (final phase in [begin, writeOn, restrict, finish]) {
      expect(phase, contains('withQueueLock'));
    }
    final purge = body(store, 'static func purgeUserOwnedState()');
    expect(purge, isNot(contains('pendingStateKC')));
    expect(purge, isNot(contains('pendingStateFileName')));
  });

  test('no phase mints or changes an owner, a generation, an epoch or a key',
      () {
    for (final forbidden in [
      'publishActiveOwner',
      'bumpOwnerEpoch',
      'ownerGenerationKey',
      'activeOwnerKC',
      'writeKeychain(',
      'uidHash(', // creates the HMAC key; the phases use keyedOwnerHash
      'uidHmacKey()',
    ]) {
      expect(section, isNot(contains(forbidden)), reason: forbidden);
    }
    expect(section, contains('private static func keyedOwnerHash('));
    expect(section, contains('private static func liveOwner('));
  });

  test('restrictive publication is a separate flock operation, never called by phases', () {
    expect(restrictivePublication, contains('withQueueLock'));
    expect(restrictivePublication, contains('ownerGenerationKey'));
    expect(restrictivePublication, contains('writeStateLayer(.egress'));
    expect(restrictivePublication, contains('egressLayerRead(layer)'));
    for (final phase in [begin, writeOn, restrict, finish]) {
      expect(phase, isNot(contains('publishRestrictiveCaptureOwner')));
      expect(phase, isNot(contains('publishActiveOwner')));
    }
  });

  test('begin: bound to the committed owner, never adopts, never reconstructs',
      () {
    expect(begin, contains('liveOwner(matching: owner)'));
    expect(begin, contains('.ownerMismatch'));
    expect(begin, contains('view.anyUnreadable'));
    expect(begin.indexOf('view.anyUnreadable'),
        lessThan(begin.indexOf('writeStateLayer')),
        reason: 'an unreadable layer is judged before any write');
    // explicit resume only: the original id AND the original owner epoch
    expect(begin, contains('resumeOperationId'));
    expect(begin, contains('first.ownerEpoch == resumeEpoch'));
    expect(begin, contains('return transition("begin", .conflict'));
    // each layer is rebuilt from its own content, never merged across layers
    expect(section, isNot(contains('otherPendingOwners')));
    expect(begin, contains('if case let .value(map) = view.layer(layer)'));
    // a begin writes only the pending store
    expect(begin, isNot(contains('.egress,')));
    expect(begin, isNot(contains('setCloudEgressState')));
  });

  test('writeOn: live owner binding, per-layer egress maps, no merge', () {
    expect(writeOn, contains('live.generation == expected.ownerGeneration'));
    expect(writeOn, contains('live.epoch == expected.ownerEpoch'));
    expect(writeOn, contains('readBarrier()'));
    expect(writeOn, isNot(contains('merged')));
    expect(writeOn, isNot(contains('egressRank')));
  });

  test('writeOn: every new ON is explicitly bound to the verified operation', () {
    // N-R2: security metadata comes from the verified pending operation and the
    // exact live owner, never from whichever old entry happens to be first.
    expect(writeOn, isNot(contains('lifecycleEntries.first')));
    expect(writeOn, isNot(contains('metadata?.')));
    expect(writeOn, contains('lifetimeOwnerGeneration: expected.ownerGeneration'));
    expect(writeOn, contains('lifetimeOwnerEpoch: expected.ownerEpoch'));
    // the exact live match is required strictly before any egress write
    expect(writeOn.indexOf('live.epoch == expected.ownerEpoch'),
        lessThan(writeOn.indexOf('writeStateLayer(.egress')));
    // half-bound lifecycle metadata (either field) is refused, not tolerated
    expect(writeOn, contains(r'$0.lifetimeOwnerGeneration != nil || $0.lifetimeOwnerEpoch != nil'));
  });

  test('finish: completion validates the exact bound ON, not an inferred one', () {
    expect(finish, isNot(contains('lifecycleEntries.first')));
    expect(finish, isNot(contains('metadata?.')));
    expect(finish, contains('lifetimeOwnerGeneration: expected.ownerGeneration'));
    expect(finish, contains('lifetimeOwnerEpoch: expected.ownerEpoch'));
    expect(finish, contains(r'entries.allSatisfy({ $0 == target })'));
    expect(finish, contains(r'$0.lifetimeOwnerGeneration != nil || $0.lifetimeOwnerEpoch != nil'));
  });

  test('snapshot: a bound ON needs the requested active owner and two equal layers',
      () {
    final snapshot = body(store, 'static func cloudEgressState(forUid uid: String)');
    final restrictiveFirst = snapshot.indexOf(r'filter({ $0.state != "ON" })');
    final bound = snapshot.indexOf('// N-R1 bound-ON');
    final returnsOn = snapshot.indexOf('return .record(mine[0])');
    expect(restrictiveFirst, greaterThan(-1));
    expect(bound, greaterThan(restrictiveFirst),
        reason: 'restrictive OFF/DISABLING reporting stays ahead of ON eligibility');
    expect(returnsOn, greaterThan(bound),
        reason: 'the bound check precedes any ON being returned');
    final gate = snapshot.substring(bound, returnsOn);
    expect(gate, contains('owner.uid == normalized'));
    expect(gate, contains('owner.uidHash == hash'));
    expect(gate, contains('mine.count == 2'));
    expect(gate, contains(r'$0.state == "ON" && $0.retirement == nil'));
    expect(gate, contains(r'$0.lifetimeOwnerGeneration == owner.generation'));
    expect(gate, contains(r'$0.lifetimeOwnerEpoch == epoch'));
    expect(gate, contains('return .uncertain'));
    // an inspection never writes anything
    for (final write in [
      'writeStateLayer(',
      'removeStateLayer(',
      'writeKeychain(',
      'bumpOwnerEpoch',
      'publishActiveOwner',
      'defaults.set(',
      'uidHash(',
      'uidHmacKey()',
    ]) {
      expect(snapshot, isNot(contains(write)), reason: write);
    }
  });

  test('restrict: only a barrier-proven operation may be compensated', () {
    final check = restrict.indexOf('switch checkBarrier(');
    expect(check, greaterThan(-1));
    expect(check, lessThan(restrict.indexOf('writeStateLayer')),
        reason: 'the proof comes before any write');
    final gate = restrict.substring(check, restrict.indexOf('var clean'));
    for (final status in ['.noBarrier', '.conflict', '.uncertain']) {
      expect(gate, contains('return transition("restrict", $status'),
          reason: '$status writes nothing');
    }
    expect(restrict, isNot(contains('removeStateLayer')));
    expect(restrict, isNot(contains('.pending,')),
        reason: 'compensation never touches the barrier');
  });

  test('restrict: each egress layer needs ITS OWN barrier proof before a write',
      () {
    // The proof is checked against the same layer's barrier entry...
    expect(restrict, contains('guard view.entry(hash, in: layer) == expected'));
    // ...strictly before that layer's egress write, and its failure is reported
    // as unresolved (notOurs / incomplete), never as a restriction.
    final proof = restrict.indexOf('guard view.entry(hash, in: layer) == expected');
    expect(proof, lessThan(restrict.indexOf('writeStateLayer')),
        reason: 'no write precedes the per-layer proof');
    final refusal = restrict.substring(proof, restrict.indexOf('writeStateLayer'));
    expect(refusal, contains('clean = false'));
    expect(refusal, contains('.notOurs'));
    expect(refusal, isNot(contains('.restricted')));
    // The overall gate (any unreadable / different / missing barrier = no write)
    // stays in front of the per-layer proof.
    expect(restrict.indexOf('switch checkBarrier('), lessThan(proof));
    // Only the single write site exists: no loop writes every matching layer
    // from one shared proof.
    expect(RegExp('writeStateLayer').allMatches(restrict).length, 1);
  });

  test('finish: complete re-reads owner and removal barrier; abandon needs no ON',
      () {
    expect(finish, contains('if !abandon { guard try readBarrier() == nil'));
    expect(finish, contains('live.generation == expected.ownerGeneration'));
    expect(finish, contains('live.epoch == expected.ownerEpoch'));
    expect(finish.indexOf('liveOwner(matching: owner)'),
        lessThan(finish.indexOf('removeStateLayer')));
    // abandon: any ON at all keeps the denial; no older-generation exemption
    expect(finish, contains(r'entries.contains(where: { $0?.state == "ON" })'));
    expect(finish, isNot(contains('>= transitionGeneration')));
  });

  test('every native admission path asks the barrier', () {
    final denied = body(store, 'private static func egressDenied(');
    expect(denied, contains('pendingView()'));
    expect(denied, contains('pending.anyUnreadable'));
    expect(denied, contains('pending.holds(hash)'));
    // a half-bound record (either lifetime field) takes the bound-ON path
    expect(denied,
        contains(r'$0.lifetimeOwnerGeneration != nil || $0.lifetimeOwnerEpoch != nil'));
    final legacy = body(store, 'static func setCloudEgressState(');
    expect(legacy, contains('pending.holds(hash)'));
    expect(
        legacy.indexOf('pending.holds(hash)'),
        lessThan(legacy.indexOf('SharedKeychain.writeData')),
        reason: 'a legacy ON is refused before anything is written');
    final host = body(store, 'static func egressAdmitsHostRequest(');
    expect(host, contains('pendingView().holdsAny'));
    final ownerless = body(store, 'private static func ownerlessEgressSnapshot(');
    expect(ownerless, contains('holdsAny'));
  });

  test('test seams are DEBUG-only and inert constants in release', () {
    final debug = store.indexOf('#if DEBUG');
    final release = store.indexOf('#else', debug);
    final end = store.indexOf('#endif', release);
    expect(store.substring(debug, release),
        contains('static var stateLayerWriteFault'));
    expect(store.substring(debug, release),
        contains('static var pendingKeychainReadOverride'));
    expect(store.substring(release, end),
        contains('static let stateLayerWriteFault'));
    expect(store.substring(release, end),
        contains('static let pendingKeychainReadOverride'));
  });

  test('the channel carries the owner binding both ways and rejects half a resume',
      () {
    expect(appDelegate, contains('"beginCloudEgressEnable"'));
    expect(appDelegate, contains('args["ownerGeneration"] as? Int'));
    expect(appDelegate, contains('args["ownerEpoch"] as? Int'));
    expect(appDelegate, contains('(resumeId == nil) == (resumeEpoch == nil)'));
    expect(appDelegate, contains('map["ownerGeneration"]'));
    expect(appDelegate, contains('map["ownerEpoch"]'));
  });
}
