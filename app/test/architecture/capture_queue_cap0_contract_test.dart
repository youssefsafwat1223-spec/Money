import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CAP-0 — the capture queue must never lose data to a Keychain or lock error.
///
/// Proven defects at b28bb001: (1) a Keychain read that failed for ANY reason
/// (e.g. `errSecInteractionNotAllowed` before first unlock) generated a new
/// queue key, deleted the old one and made the existing encrypted queue
/// permanently undecryptable; (2) an unreadable queue was reported as EMPTY, so
/// the next enqueue overwrote it; (3) `withQueueLock` ran its body UNLOCKED when
/// the container, the lock file or the flock failed; (4) the App Intent
/// returned a quiet result when persistence failed.
///
/// Swift cannot run here. The behavioural proof is `ios/RunnerTests/
/// RunnerTests.swift` (T-Q1..T-Q4, needs Xcode); these static checks pin the
/// source properties that make it true so a regression fails in CI.
void main() {
  final store = File('ios/Runner/SharedCaptureStore.swift').readAsStringSync();
  final intent =
      File('ios/BankMessageShortcuts/BankMessageShortcuts.swift')
          .readAsStringSync();
  final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final share =
      File('ios/ShareBankMessage/ShareViewController.swift').readAsStringSync();
  final xctest = File('ios/RunnerTests/RunnerTests.swift').readAsStringSync();

  /// The text from the `{` after [signature] to its matching `}`.
  String body(String source, String signature) {
    final at = source.indexOf(signature);
    expect(at, greaterThan(-1), reason: '$signature not found');
    final open = source.indexOf('{', at + signature.length);
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}' && --depth == 0) {
        return source.substring(open, i + 1);
      }
    }
    fail('unbalanced braces after $signature');
  }

  group('queue key', () {
    test('a key is generated ONLY under errSecItemNotFound', () {
      expect('SymmetricKey(size:'.allMatches(store).length, 1,
          reason: 'exactly one place may mint a queue key');
      final fn = body(store, 'private static func encryptionKey()');
      final notFound = fn.indexOf('case errSecItemNotFound:');
      final generate = fn.indexOf('SymmetricKey(size:');
      final fallthrough = fn.indexOf('default:');
      expect(notFound, greaterThan(-1));
      expect(generate, greaterThan(notFound),
          reason: 'key generation must sit inside the errSecItemNotFound case');
      expect(generate, lessThan(fallthrough),
          reason: 'and must not be reachable from the default (error) case');
      expect(fn.substring(fallthrough), contains('throw QueueError.keyUnavailable'),
          reason: 'any other Keychain status must fail the operation');
    });

    test('the read path never creates a key and never reports "empty"', () {
      final decode = body(store, 'private static func decodeQueueBlob(');
      expect(decode, isNot(contains('encryptionKey()')),
          reason: 'loading must only READ the key');
      expect(decode, isNot(contains('SymmetricKey(size:')));
      expect(decode, contains('throw QueueError.keyUnavailable'));
      expect(decode, contains('throw QueueError.unreadable'),
          reason: 'an undecryptable blob must fail, not become []');
      final load = body(store, 'private static func loadQueue()');
      expect(load, isNot(contains('?? []')));
      expect(load, contains('try decodeQueueBlob'));
    });

    test('the key is written with SecItemUpdate, never delete-then-add', () {
      final write = body(store, 'static func writeData(');
      expect(write, contains('SecItemUpdate('));
      expect(write, contains('SecItemAdd('));
      expect(write.indexOf('SecItemUpdate('),
          lessThan(write.indexOf('SecItemAdd(')));
      expect(write, contains('errSecItemNotFound'),
          reason: 'add only when the item does not exist');
      expect(write, isNot(contains('SecItemDelete')));
      final setData = body(store, 'static func setData(');
      expect(setData, isNot(contains('SecItemDelete')));
      // The only delete left is the explicit purge/remove.
      final remove = body(store, 'static func remove(forKey key: String)');
      expect('SecItemDelete('.allMatches(store).length, 1);
      expect(remove, contains('SecItemDelete('));
    });

    test('the queue format is unchanged (v2, AES-GCM blob)', () {
      expect(store, contains('"pending_bank_messages_v2"'));
      expect(store, contains('AES.GCM.seal'));
      expect(store, contains('capture_queue_key_v1'));
    });
  });

  group('queue lock', () {
    test('withQueueLock has no unlocked branch', () {
      final fn = body(store, 'private static func withQueueLock<T>(');
      expect(store, contains('func withQueueLock<T>(_ body: () throws -> T) throws -> T'));
      expect('body()'.allMatches(fn).length, 1,
          reason: 'the body may be invoked exactly once');
      expect(fn, contains('return try body()'));
      expect(fn.indexOf('return try body()'),
          greaterThan(fn.indexOf('LOCK_EX')),
          reason: 'the body runs only after the lock is taken');
      expect(fn.indexOf('return try body()'),
          greaterThan(fn.lastIndexOf('throw QueueError.lockUnavailable')),
          reason: 'every failure path throws before the body');
      expect('throw QueueError.lockUnavailable'.allMatches(fn).length,
          greaterThanOrEqualTo(3),
          reason: 'no container, open() failure and flock() failure all throw');
    });

    test('every queue write is a throwing call, none swallowed into success', () {
      expect(store, contains('private static func saveQueue('));
      expect(RegExp(r'saveQueue\([^)]*\)\s*throws').hasMatch(store), isTrue);
      expect(store, isNot(contains('_ = saveQueue(')));
      expect(store, isNot(contains('guard saveQueue(')));
    });
  });

  group('visible errors', () {
    test('the App Intent throws instead of returning a quiet result', () {
      expect(intent, contains('func perform() async throws -> some IntentResult'));
      expect(intent, isNot(contains('try? service.capture')));
      expect(intent, isNot(contains('guard persisted != nil')));
      expect(intent, contains('let persisted = try service.capture('));
      expect(intent, contains('let outcome = try service.capture('));
    });

    test('method-channel queue calls surface a FlutterError', () {
      expect(appDelegate, contains('"queue_unavailable"'));
      for (final call in const [
        'consumePendingText()',
        'consumePendingPayloadsJSON()',
        'peekPendingPayloadsJSON()',
      ]) {
        expect(appDelegate, contains('try SharedCaptureStore.$call'));
      }
      expect(appDelegate, isNot(contains('result(SharedCaptureStore.peekPending')));
    });

    test('the share extension does not report a lost share as success', () {
      expect(share, contains('case let .failed(reason) = SharedCaptureStore.enqueue'));
      expect(share, contains('cancelRequest(withError:'));
    });

    test('the XCTest cases for T-Q1..T-Q4 exist', () {
      for (final name in const [
        'testKeyReadErrorFailsWithoutNewKeyAndKeepsBlob',
        'testLockUnavailableThrowsAndWritesNothing',
        'testUnreadableBlobIsNeverOverwritten',
        'testIntentThrowsVisibleErrorWhenQueueUnavailable',
      ]) {
        expect(xctest, contains('func $name('));
      }
      expect(xctest, contains('errSecInteractionNotAllowed'));
    });
  });
}
