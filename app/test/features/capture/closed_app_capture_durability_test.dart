// H-19 — closed-app Shortcut capture DURABILITY.
//
// A capture the product reports as successful (the App Intent showed a
// notification) must not silently disappear just because Flutter was not opened
// before the server relay's 30-day TTL expired. The relay
// (`processed_captures`, swept unconditionally by run_prune_processed_captures)
// is NOT the authoritative local store.
//
// The defect was in the iOS App Intent (BankMessageShortcuts.swift): on backend
// success it DELETED the durable App Group copy, leaving the expiring relay row
// as the only copy. The fix retains it as `.sent`, so the host's per-item lease
// drain — which already imports locally on-device when the relay pull did not —
// recovers it whatever the relay's state.
//
// This models that end-to-end contract against a real file-backed durable queue
// and the exact drain sequence app_shell runs: relay-pull FIRST, then peek →
// import-if-not-already → ack, with a permanent payloadId dedup set (mirroring
// dedup_hashes, whose `capture_payload:%` markers are never pruned). It proves
// the retained copy survives relay expiry and yields EXACTLY ONE import, and
// that the pre-fix "removed on success" copy is unrecoverable — the loss the fix
// prevents.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Durable App Group queue mirror: durable writes, non-destructive peek, per-id
/// ack. Entries carry a status like the real SharedCaptureStore payloads.
class NativeQueue {
  NativeQueue(this.file);
  final File file;

  List<Map<String, dynamic>> _read() {
    if (!file.existsSync()) return [];
    return (jsonDecode(file.readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
  }

  void _write(List<Map<String, dynamic>> items) =>
      file.writeAsStringSync(jsonEncode(items), flush: true);

  /// The App Intent's success action AFTER the fix: keep a durable `.sent` copy.
  void retainSent(String id, String text) {
    final items = _read();
    final i = items.indexWhere((e) => e['id'] == id);
    if (i >= 0) {
      items[i] = {'id': id, 'text': text, 'status': 'sent'};
    } else {
      items.add({'id': id, 'text': text, 'status': 'sent'});
    }
    _write(items);
  }

  List<Map<String, dynamic>> peek() => _read(); // NON-destructive lease
  void ack(String id) => _write(_read()..removeWhere((e) => e['id'] == id));
}

/// The server relay (`processed_captures`). A 30-day sweep = clearing it.
class Relay {
  final Map<String, String> _rows = {}; // payloadId -> parsed text
  void store(String id, String text) => _rows[id] = text;
  void sweepAll() => _rows.clear(); // run_prune_processed_captures at 30 days
  List<MapEntry<String, String>> pull() => _rows.entries.toList();
  void ack(String id) => _rows.remove(id);
}

void main() {
  late Directory dir;
  late File queueFile;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mali_h19');
    queueFile = File('${dir.path}/native_queue.json');
  });
  tearDown(() async => dir.delete(recursive: true));

  /// The app_shell drain contract: relay pull FIRST (server parse wins when
  /// present), then peek the native queue and import locally anything the pull
  /// did not, acking each only after its Drift import committed. [imported] is
  /// the permanent payloadId dedup set. Returns the number of Drift rows written
  /// this run. [localImports] records ids imported from the native copy.
  int drain(
    NativeQueue queue,
    Relay relay,
    Set<String> imported, {
    required List<String> driftRows,
    required List<String> localImports,
  }) {
    var wrote = 0;
    // 1) Relay pull first: import + ack + mark, deleting the server row.
    for (final row in relay.pull()) {
      if (imported.add(row.key)) {
        driftRows.add(row.key);
        wrote++;
      }
      relay.ack(row.key); // server row consumed
    }
    // 2) Native queue drain: import locally anything not already imported.
    for (final item in queue.peek()) {
      final id = item['id'] as String;
      if (imported.contains(id)) {
        queue.ack(id); // already imported (by the relay pull) → ack + skip
        continue;
      }
      // On-device local import (cloud-independent) — the recovery the fix enables.
      driftRows.add(id);
      localImports.add(id);
      imported.add(id);
      wrote++;
      queue.ack(id);
    }
    return wrote;
  }

  test('retained .sent copy survives relay expiry and imports locally (no loss)',
      () {
    final queue = NativeQueue(queueFile);
    final relay = Relay();
    final imported = <String>{};

    // Day 0: cloud-ON Shortcut, backend succeeds. Fix retains a durable copy;
    // the relay also has the parsed row.
    queue.retainSent('p1', 'شراء 100 SAR');
    relay.store('p1', 'شراء 100 SAR');

    // Day 40, app opened for the first time: the relay row was swept at 30 days.
    relay.sweepAll();

    final drift = <String>[];
    final local = <String>[];
    final wrote = drain(queue, relay, imported, driftRows: drift, localImports: local);

    expect(wrote, 1, reason: 'the capture must still be imported exactly once');
    expect(drift, ['p1']);
    expect(local, ['p1'], reason: 'recovered from the retained local copy');
    expect(queue.peek(), isEmpty, reason: 'acked only after the local import');
  });

  test('pre-fix "removed on success" copy + expired relay = permanent loss', () {
    // The pre-fix App Intent deleted the copy on backend success, so nothing is
    // in the native queue; the relay then expires. This documents the defect.
    final queue = NativeQueue(queueFile); // nothing retained
    final relay = Relay()..store('p1', 'شراء 100 SAR');
    relay.sweepAll();

    final drift = <String>[];
    final local = <String>[];
    final wrote = drain(queue, relay, <String>{}, driftRows: drift, localImports: local);

    expect(wrote, 0, reason: 'the capture is unrecoverable — the H-19 data loss');
    expect(drift, isEmpty);
  });

  test('relay still present → relay pull wins, local copy acked (exactly one)',
      () {
    final queue = NativeQueue(queueFile);
    final relay = Relay();
    final imported = <String>{};

    queue.retainSent('p2', 'إيداع 50 SAR');
    relay.store('p2', 'إيداع 50 SAR'); // opened within 30 days: relay alive

    final drift = <String>[];
    final local = <String>[];
    final wrote = drain(queue, relay, imported, driftRows: drift, localImports: local);

    expect(wrote, 1, reason: 'one transaction, not two');
    expect(local, isEmpty, reason: 'the relay pull imported it; local copy only acked');
    expect(queue.peek(), isEmpty);
  });

  test('idempotent: crash after commit before ack → replay creates no duplicate',
      () {
    final queue = NativeQueue(queueFile)..retainSent('p3', 'x');
    // Import committed + payloadId marked, but the process died before ack, so
    // the .sent copy is still leased.
    final imported = <String>{'p3'};
    final relay = Relay();

    final drift = <String>[];
    final local = <String>[];
    final wrote = drain(queue, relay, imported, driftRows: drift, localImports: local);

    expect(wrote, 0, reason: 'already imported → no second Drift row');
    expect(drift, isEmpty);
    expect(queue.peek(), isEmpty, reason: 'acked, never re-imported');
  });

  test('duplicate Shortcut execution of the same payload imports once', () {
    final queue = NativeQueue(queueFile)
      ..retainSent('p4', 'شراء 20 SAR')
      ..retainSent('p4', 'شراء 20 SAR'); // same payloadId, deterministic hash
    expect(queue.peek().length, 1, reason: 'same-id retain is idempotent');

    final relay = Relay();
    final drift = <String>[];
    final local = <String>[];
    drain(queue, relay, <String>{}, driftRows: drift, localImports: local);
    expect(drift, ['p4'], reason: 'exactly one logical transaction');
  });
}
