// MALI-068n — behavioral proof of the native-queue LEASE contract that the
// Android DurableCaptureQueue (Kotlin) + the app_shell drain implement.
//
// The Kotlin queue itself can't run without the Android SDK/JVM (compilation +
// on-device process-death are external). This test models the SAME contract
// against a real FILE-backed durable store and drives the exact drain sequence
// (peek → handle → ack ONLY on success) to prove the persistence/lease/replay
// behavior locally: peek never removes, a failed handle leaves the item, ack
// removes exactly one, items survive a "restart", and idempotent replay creates
// no duplicate. The Kotlin source enforces the same shape (commit()-before-
// return, peekJson non-destructive, per-id remove) — see
// exact_alarm_contract_test.dart / the C5 static review.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A file-backed queue mirroring DurableCaptureQueue: durable writes, a
/// non-destructive peek, and a per-id acknowledge. A "restart" is a fresh
/// instance over the same file.
class FileBackedQueue {
  FileBackedQueue(this.file);
  final File file;

  List<Map<String, dynamic>> _read() {
    if (!file.existsSync()) return [];
    return (jsonDecode(file.readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
  }

  void _write(List<Map<String, dynamic>> items) =>
      file.writeAsStringSync(jsonEncode(items), flush: true); // durable

  void enqueue(String id, String text) {
    final items = _read();
    if (items.any((i) => i['id'] == id)) return; // idempotent enqueue
    items.add({'id': id, 'text': text});
    _write(items);
  }

  List<Map<String, dynamic>> peek() => _read(); // NON-destructive
  void ack(String id) => _write(_read()..removeWhere((i) => i['id'] == id));
}

void main() {
  late Directory dir;
  late File queueFile;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mali_queue');
    queueFile = File('${dir.path}/queue.json');
  });
  tearDown(() async => dir.delete(recursive: true));

  /// The drain contract: peek, handle each, ack ONLY when the handler committed.
  /// [handle] returns true on a committed import. [imported] is the durable
  /// dedup set (payload ids already committed), making replay idempotent.
  int drain(
    FileBackedQueue queue,
    Set<String> imported,
    bool Function(String id) handle,
  ) {
    var processedNow = 0;
    for (final item in queue.peek()) {
      final id = item['id'] as String;
      if (imported.contains(id)) {
        queue.ack(id); // already committed on a prior run — ack + skip (no dup)
        continue;
      }
      final committed = handle(id); // may fail (returns false / throws)
      if (committed) {
        imported.add(id); // durable dedup mark AFTER commit
        processedNow++;
        queue.ack(id); // release the lease only now
      }
      // not committed → NOT acked → stays leased for the next drain
    }
    return processedNow;
  }

  test('peek does not remove; ack removes exactly one', () {
    final q = FileBackedQueue(queueFile)..enqueue('a', 'x')..enqueue('b', 'y');
    expect(q.peek().length, 2);
    expect(q.peek().length, 2); // peeking again still shows both (lease)
    q.ack('a');
    expect(q.peek().map((i) => i['id']), ['b']);
  });

  test('a failed handle leaves the item; it survives a restart and retries', () {
    final q = FileBackedQueue(queueFile)..enqueue('a', 'x');
    final imported = <String>{};
    // First drain: the import fails (crash before commit) → not acked.
    drain(q, imported, (_) => false);
    expect(q.peek().length, 1, reason: 'unacked item remains');

    // Restart: a fresh queue over the same file still holds it.
    final restarted = FileBackedQueue(queueFile);
    expect(restarted.peek().length, 1);

    // Second drain: import commits → acked → gone.
    final processed = drain(restarted, imported, (_) => true);
    expect(processed, 1);
    expect(restarted.peek(), isEmpty);
  });

  test('crash after commit before ack → replay is idempotent (no duplicate)',
      () {
    final q = FileBackedQueue(queueFile)..enqueue('a', 'x');
    final imported = <String>{};
    // Simulate: import committed + dedup marked, but the process died before
    // ack (so the item is still in the queue).
    imported.add('a');
    // Next drain sees it already imported → acks + skips, never re-imports.
    final processed = drain(q, imported, (_) {
      fail('handle must NOT run for an already-imported payload');
    });
    expect(processed, 0);
    expect(q.peek(), isEmpty); // acked, not re-processed
  });

  test('duplicate enqueue of the same id is ignored (bounded, no double)', () {
    final q = FileBackedQueue(queueFile)
      ..enqueue('a', 'x')
      ..enqueue('a', 'x-again');
    expect(q.peek().length, 1);
  });
}
