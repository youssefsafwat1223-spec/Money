import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// AUDIT 4 — THE SHARED CAPTURE QUEUE IS WRITTEN BY TWO PROCESSES.
///
/// The notification-service extension and the host app are separate OS
/// processes that both mutate one queue in the App Group container. Every
/// mutation is a read-modify-write — `loadQueue()`, change, `saveQueue()` — so
/// without mutual exclusion two interleaved writers lose whichever change
/// landed first. For this queue that means a captured bank SMS is silently
/// dropped, or an acknowledged one comes back and is imported twice.
///
/// `SharedCaptureStore.withQueueLock` is the mutual exclusion: an `flock(LOCK_EX)`
/// on a file inside the App Group container, which is what makes it work ACROSS
/// processes — a `DispatchQueue` or an `NSLock` would only serialise within one.
///
/// Swift is not reachable from a Dart test, so what is pinned here is the
/// property that makes the locking correct: no read-modify-write of the queue
/// may sit outside a `withQueueLock` block. That is checked by locating each
/// block's real extent with brace tracking rather than by grepping for a nearby
/// string, so a call added just after a lock block — the natural way to
/// introduce this bug — is still caught.
void main() {
  final source =
      File('${Directory.current.path}/ios/Runner/SharedCaptureStore.swift')
          .readAsStringSync();

  /// The `[start, end)` character extents of every `withQueueLock { ... }` body.
  List<({int start, int end})> lockBlocks() {
    final blocks = <({int start, int end})>[];
    for (final match in RegExp(r'withQueueLock\s*\{').allMatches(source)) {
      var depth = 0;
      final open = source.indexOf('{', match.start);
      for (var i = open; i < source.length; i++) {
        if (source[i] == '{') depth++;
        if (source[i] == '}') {
          depth--;
          if (depth == 0) {
            blocks.add((start: open, end: i));
            break;
          }
        }
      }
    }
    return blocks;
  }

  bool insideALock(int offset, List<({int start, int end})> blocks) =>
      blocks.any((b) => offset > b.start && offset < b.end);

  test('the lock is a cross-PROCESS file lock, not an in-process one', () {
    final at = source.indexOf('func withQueueLock');
    expect(at, greaterThan(-1), reason: 'withQueueLock must exist');
    final body = source.substring(at, at + 700);

    expect(body, contains('containerURL('),
        reason: 'the lock file must live in the APP GROUP container — a lock '
            'anywhere else is not shared with the extension process');
    expect(body, contains('LOCK_EX'),
        reason: 'an exclusive flock is what serialises the two processes');
    expect(body, contains('flock(fd, LOCK_UN)'),
        reason: 'it must be released, or the next launch deadlocks');
    expect(body, contains('defer { flock(fd, LOCK_UN) }'),
        reason: 'release must be in a defer so an early return still unlocks');
    expect(body, contains('defer { close(fd) }'),
        reason: 'the descriptor must not leak');
  });

  test('every queue MUTATION happens inside the lock', () {
    final blocks = lockBlocks();
    expect(blocks, isNotEmpty, reason: 'no withQueueLock blocks found at all');

    // A bare `loadQueue()` read is fine: the blob is set under one key, so a
    // reader sees either the old value or the new one, never a mix, and a stale
    // answer self-corrects on the next drain. `hasPendingMessages()` reads that
    // way deliberately. What must be serialised is the read-MODIFY-write, which
    // is exactly the `var queue = loadQueue()` ... `saveQueue(queue)` shape.
    for (final call in RegExp(r'var queue = loadQueue\(').allMatches(source)) {
      expect(insideALock(call.start, blocks), isTrue,
          reason: 'a read-modify-write of the queue at offset ${call.start} is '
              'OUTSIDE withQueueLock — two processes can then interleave and '
              'silently drop a captured bank message');
    }

    final saveDef = source.indexOf('func saveQueue');
    for (final call in RegExp(r'saveQueue\(').allMatches(source)) {
      if (call.start > saveDef && call.start < saveDef + 40) continue;
      expect(insideALock(call.start, blocks), isTrue,
          reason: 'saveQueue is called OUTSIDE withQueueLock at offset '
              '${call.start} — the write would race the other process');
    }
  });

  test('the queue blob is never mutated outside the lock', () {
    // Direct UserDefaults mutations of the queue key, wherever they are. Each
    // must sit in a lock block, or inside saveQueue — which the test above
    // proves is only ever reached under one.
    final blocks = lockBlocks();
    final saveDef = source.indexOf('func saveQueue');
    final saveEnd = source.indexOf('\n  }', saveDef);

    final mutations = [
      ...RegExp(r'defaults\?\.set\([^)]*forKey:\s*queueKey')
          .allMatches(source),
      ...RegExp(r'defaults\?\.removeObject\(forKey:\s*queueKey')
          .allMatches(source),
    ];
    expect(mutations, isNotEmpty, reason: 'the queue must be written somewhere');

    for (final m in mutations) {
      final inSaveQueue = m.start > saveDef && m.start < saveEnd;
      expect(insideALock(m.start, blocks) || inSaveQueue, isTrue,
          reason: 'the queue blob is mutated outside any lock at offset '
              '${m.start}');
    }
  });

  test('the raw queue is encrypted at rest and holds no secret material', () {
    // The queue contains raw bank SMS text, which is why it is encrypted; the
    // KEY for it must live in the Keychain, never beside the data it protects.
    expect(source, contains('encodeQueueBlob'),
        reason: 'the queue is stored as an encrypted blob');
    expect(source, contains('capture_queue_key_v1'));
    final at = source.indexOf('capture_queue_key_v1');
    final keyLine = source.substring(at - 500 < 0 ? 0 : at - 500, at + 60);
    expect(keyLine.toLowerCase(), contains('keychain'),
        reason: 'the encryption key belongs in the Keychain, not UserDefaults');
  });
}
