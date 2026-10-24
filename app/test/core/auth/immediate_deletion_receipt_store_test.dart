import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/auth/immediate_account_deletion.dart';
import 'package:money_companion/core/auth/immediate_deletion_receipt_store.dart';
import 'package:money_companion/data/db/database_key_store.dart';

import '../../harness/egress_test_support.dart';

const _secret = 'RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR';
final _url = Uri.parse('https://example.supabase.co/functions/v1/delete-account-immediate');
http.Response _reply(String status, [int code = 200]) => http.Response(jsonEncode({'status': status}), code);

class _Custody {
  final authority = Object();
  final values = <String, String>{};
  final sent = <http.Request>[];
  final egress = TestEgress().install();
  String? owner = 'uid-a';
  int life = 1;
  int reads = 0;
  int writes = 0;
  int secrets = 0;
  int operations = 0;
  Future<void> Function(int)? onRead;
  Future<void> Function(int, String)? onWrite;
  Future<void> Function()? prepare;
  bool throwAfterWrite = false;
  Future<http.Response> Function(http.Request) answer = (_) async => _reply('in_progress', 202);

  ImmediateDeletionReceiptStore get store => ImmediateDeletionReceiptStore(
    authority: authority,
    read: (key) async { await onRead?.call(++reads); return values[key]; },
    write: (key, value) async {
      await onWrite?.call(++writes, value);
      values[key] = value;
      if (throwAfterWrite) throw StateError('private-storage-provider-text');
    },
  );

  ImmediateAccountDeletionRecovery facade({bool latestAfterPrepare = false}) => ImmediateAccountDeletionRecovery(
    store: store,
    transport: MockClient((r) async { sent.add(r); return answer(r); }),
    functionUrl: _url,
    newReceipt: () { secrets++; return _secret; },
    newOperationId: () => 'operation-${++operations}',
    captureBinding: () async {
      final binding = ImmediateDeletionBinding(owner: owner, lifecycle: life,
          bearerToken: owner == null ? null : 'coherent-token');
      await prepare?.call();
      return latestAfterPrepare
          ? ImmediateDeletionBinding(owner: owner, lifecycle: life,
              bearerToken: owner == null ? null : 'coherent-token')
          : binding;
    },
    isBindingCurrent: (b) => b.owner == owner && b.lifecycle == life,
  );

  void transition(String? next) {
    owner = next;
    egress.owner = next;
    life++;
    egress.gate.advanceEpoch();
  }

  Future<ImmediateDeletionResult> request(ImmediateAccountDeletionRecovery f, {String? secret}) =>
      f.request(challengeId: 'challenge', challengeResponse: 'proof-never-stored', receiptSecret: secret);
  Future<ImmediateDeletionReceipt?> load() => store.load('uid-a');
}

void main() {
  group('abandoning and deferred retirement', () {
    test('deleteVerified removes the record and proves it is gone; a store '
        'without delete fails closed', () async {
      final values = <String, String>{};
      final store = ImmediateDeletionReceiptStore(
        authority: Object(),
        read: (k) async => values[k],
        write: (k, v) async => values[k] = v,
        delete: (k) async => values.remove(k),
      );
      await store.writeVerified(const ImmediateDeletionReceipt(
          owner: 'uid-a',
          operationId: 'op',
          receiptSecret: _secret,
          phase: ImmediateDeletionPhase.mayHaveBeenSent));
      await store.deleteVerified('uid-a');
      expect(await store.load('uid-a'), isNull);

      final noDelete = ImmediateDeletionReceiptStore(
          authority: Object(),
          read: (k) async => 'x',
          write: (k, v) async {});
      expect(() => noDelete.deleteVerified('uid-a'),
          throwsA(isA<ImmediateDeletionReceiptStoreException>()));
      final stuck = ImmediateDeletionReceiptStore(
          authority: Object(),
          read: (k) async => values[k],
          write: (k, v) async => values[k] = v,
          delete: (k) async {});
      await stuck.writeVerified(const ImmediateDeletionReceipt(
          owner: 'uid-a',
          operationId: 'op',
          receiptSecret: _secret,
          phase: ImmediateDeletionPhase.mayHaveBeenSent));
      expect(() => stuck.deleteVerified('uid-a'),
          throwsA(isA<ImmediateDeletionReceiptStoreException>()),
          reason: 'a delete that did not take effect is never reported');
    });

    test('retireOnComplete: false keeps the completed receipt secret; a handle '
        'on it can re-verify completion with a status call only', () async {
      final c = _Custody();
      final retain = ImmediateAccountDeletionRecovery(
        store: c.store,
        transport: MockClient((r) async { c.sent.add(r); return c.answer(r); }),
        functionUrl: _url,
        retireOnComplete: false,
        newReceipt: () => _secret,
        newOperationId: () => 'operation-1',
        captureBinding: () async => ImmediateDeletionBinding(
            owner: c.owner, lifecycle: c.life, bearerToken: 'coherent-token'),
        isBindingCurrent: (b) => b.owner == c.owner && b.lifecycle == c.life,
      );
      c.answer = (_) async => _reply('completed');
      expect(await c.request(retain), isA<ImmediateDeletionCompleted>());
      final kept = (await c.load())!;
      expect(kept.phase, ImmediateDeletionPhase.completed);
      expect(kept.receiptSecret, _secret);
      expect(await retain.restore(owner: 'uid-a'), isNull,
          reason: 'the ordinary restore never reopens a completed receipt');
      final handle =
          (await retain.restoreCompletedAwaitingCleanup(owner: 'uid-a'))!;
      c.sent.clear();
      expect(await retain.recover(handle), isA<ImmediateDeletionCompleted>());
      expect(jsonDecode(c.sent.single.body),
          {'action': 'status', 'receipt_secret': _secret});
    });
  });

  group('durable custody before dispatch', () {
    for (final stage in ['create', 'readback', 'intent']) {
      test('$stage deferred persistence sends zero HTTP until matching readback', () async {
        final h = _Custody();
        final arrived = Completer<void>();
        final release = Completer<void>();
        if (stage == 'readback') {
          h.onRead = (n) async { if (n == 2) { arrived.complete(); await release.future; } };
        } else {
          h.onWrite = (n, _) async {
            if (n == (stage == 'create' ? 1 : 2)) { arrived.complete(); await release.future; }
          };
        }
        final future = h.request(h.facade());
        await arrived.future;
        expect(h.sent, isEmpty);
        release.complete();
        expect(await future, isA<ImmediateDeletionInProgress>());
        expect(h.sent.length, 1);
        expect((await h.load())!.phase, ImmediateDeletionPhase.mayHaveBeenSent);
        expect(h.values.values.single, isNot(contains('proof-never-stored')));
        expect(h.values.values.single, isNot(contains('coherent-token')));
      });
    }

    for (final stage in ['read', 'write', 'readback', 'intent', 'ambiguous-write', 'mismatch']) {
      test('$stage failure or ambiguity sends zero HTTP and never rotates receipt', () async {
        final h = _Custody();
        h.onRead = (n) async {
          if ((stage == 'read' && n == 1) || (stage == 'readback' && n == 2)) throw StateError('storage');
          if (stage == 'mismatch' && n == 2) h.values.clear();
        };
        h.onWrite = (n, _) async {
          if ((stage == 'write' && n == 1) || (stage == 'intent' && n == 2)) throw StateError('storage');
        };
        h.throwAfterWrite = stage == 'ambiguous-write';
        final result = await h.request(h.facade());
        expect(result, isA<ImmediateDeletionFailed>());
        expect(h.sent, isEmpty);
        expect(h.secrets, lessThanOrEqualTo(1));
        if (stage == 'ambiguous-write') {
          h.throwAfterWrite = false;
          expect((await h.load())!.receiptSecret, _secret);
          expect(await h.request(h.facade()), isA<ImmediateDeletionInProgress>());
          expect(jsonDecode(h.sent.single.body)['action'], 'status');
          expect(h.secrets, 1);
        }
      });
    }

    for (final bad in ['{broken', '{"v":2}', '{"v":1}', '[]',
      '{"v":1,"owner":"uid-a","operation_id":"op","phase":"completed","extra":null}']) {
      test('corrupt/unknown record fails closed without overwriting or HTTP: $bad', () async {
        final h = _Custody();
        h.values[ImmediateDeletionReceiptStore.storageKey('uid-a')] = bad;
        expect(await h.request(h.facade()), isA<ImmediateDeletionFailed>());
        expect(h.sent, isEmpty);
        expect(h.writes, 0);
        expect(h.secrets, 0);
        expect(h.values.values.single, bad);
      });
    }

    test('two facades share one operation/receipt and second call uses status without reauthorization', () async {
      final h = _Custody();
      final arrived = Completer<void>();
      final release = Completer<http.Response>();
      h.answer = (_) { arrived.complete(); return release.future; };
      final first = h.request(h.facade());
      await arrived.future;
      final second = h.request(h.facade());
      expect(h.sent.length, 1);
      h.answer = (_) async => _reply('in_progress');
      release.completeError(StateError('lost reply'));
      expect(await first, isA<ImmediateDeletionFailed>());
      expect(await second, isA<ImmediateDeletionInProgress>());
      expect(h.secrets, 1);
      expect(h.operations, 1);
      expect(h.sent.map((r) => jsonDecode(r.body)['receipt_secret']), [_secret, _secret]);
      expect(jsonDecode(h.sent.last.body), {'action': 'status', 'receipt_secret': _secret});
      expect(h.sent.first.headers['Authorization'], 'Bearer coherent-token');
      expect(h.sent.last.headers.containsKey('Authorization'), isFalse);
    });

    test('supplied secret conflict never replaces the durable receipt', () async {
      final h = _Custody();
      await h.request(h.facade());
      final result = await h.request(h.facade(), secret: 'S' * 43) as ImmediateDeletionFailed;
      expect(result.code, 'receipt_conflict');
      expect(h.sent.length, 1);
      expect((await h.load())!.receiptSecret, _secret);
    });

    test('a supplied secret requires matching durable pending custody, never creates a retry operation', () async {
      final h = _Custody(); final f = h.facade();
      final missing = await h.request(f, secret: _secret) as ImmediateDeletionFailed;
      expect(missing.code, 'receipt_conflict');
      expect(h.values, isEmpty);
      expect(h.sent, isEmpty);
      expect(h.secrets, 0);
      await h.store.writeVerified(const ImmediateDeletionReceipt(owner: 'uid-a', operationId: 'op',
          receiptSecret: _secret, phase: ImmediateDeletionPhase.created));
      expect(await h.request(f, secret: _secret), isA<ImmediateDeletionInProgress>());
      expect(jsonDecode(h.sent.single.body), {'action': 'status', 'receipt_secret': _secret});
      expect(h.secrets, 0);
    });

    test('dedicated qirsh namespace survives existing session wipe without changing its rule', () async {
      final h = _Custody();
      await h.request(h.facade());
      h.values['session-token'] = 'remove';
      await wipeSecureStoragePreservingDatabaseKey(readAll: () async => h.values,
          delete: (key) async { h.values.remove(key); });
      expect(h.values.keys.single, startsWith('qirsh.immediate_deletion.v1.'));
      expect((await h.load())!.receiptSecret, _secret);
    });
  });

  group('explicit restart recovery and closure', () {
    for (final phase in [ImmediateDeletionPhase.created, ImmediateDeletionPhase.mayHaveBeenSent]) {
      test('restart at $phase restores without HTTP and polls only selected receipt', () async {
        final h = _Custody();
        await h.store.writeVerified(ImmediateDeletionReceipt(owner: 'uid-a', operationId: 'op',
            receiptSecret: _secret, phase: phase));
        final f = h.facade();
        final handle = await f.restore(owner: 'uid-a');
        expect(handle, isNotNull);
        expect(h.sent, isEmpty);
        expect(await f.recover(handle!), isA<ImmediateDeletionInProgress>());
        expect(jsonDecode(h.sent.single.body), {'action': 'status', 'receipt_secret': _secret});
        expect(h.secrets, 0);
      });
    }

    for (final outcome in ['unknown', 'unavailable', 'malformed', 'acceptance_unknown', 'lost', 'timeout']) {
      test('$outcome conservatively retains the same pending receipt', () async {
        final h = _Custody();
        h.answer = (_) async {
          if (outcome == 'lost') throw StateError('lost');
          if (outcome == 'timeout') throw TimeoutException('lost');
          if (outcome == 'malformed') return http.Response('[]', 200);
          if (outcome == 'acceptance_unknown') {
            return http.Response(jsonEncode({
              'status': 'error', 'code': outcome, 'retryable': true, 'recovery': 'lookup_receipt'}), 503);
          }
          return _reply(outcome, outcome == 'unknown' ? 404 : 503);
        };
        final f = h.facade();
        expect(await h.request(f), isA<ImmediateDeletionFailed>());
        expect((await h.load())!.receiptSecret, _secret);
        h.answer = (_) async => _reply('in_progress');
        expect(await h.request(h.facade()), isA<ImmediateDeletionInProgress>());
        expect(h.secrets, 1);
        expect(jsonDecode(h.sent.last.body)['action'], 'status');
      });
    }

    test('repeated explicit unknown polls never rotate or reauthorize an unaccepted created operation', () async {
      final h = _Custody();
      await h.store.writeVerified(const ImmediateDeletionReceipt(owner: 'uid-a', operationId: 'created-op',
          receiptSecret: _secret, phase: ImmediateDeletionPhase.created));
      h.answer = (_) async => _reply('unknown', 404);
      for (var i = 0; i < 3; i++) {
        final f = h.facade();
        final handle = (await f.restore(owner: 'uid-a'))!;
        expect((await f.recover(handle) as ImmediateDeletionFailed).code, 'unknown');
        expect((await h.request(f) as ImmediateDeletionFailed).code, 'unknown');
      }
      expect(h.secrets, 0);
      expect(h.operations, 0);
      expect((await h.load())!.receiptSecret, _secret);
      expect((await h.load())!.phase, ImmediateDeletionPhase.created);
      expect(h.sent.length, 6);
      for (final request in h.sent) {
        expect(jsonDecode(request.body), {'action': 'status', 'receipt_secret': _secret});
        expect(request.headers.containsKey('Authorization'), isFalse);
      }
    });

    test('definitive initial refusal keeps durable receipt and later explicit retry is status only', () async {
      final h = _Custody();
      h.answer = (_) async => http.Response(jsonEncode({'status': 'error',
          'code': 'challenge_invalid', 'retryable': false}), 400);
      final f = h.facade();
      final refusal = await h.request(f) as ImmediateDeletionFailed;
      expect(refusal.code, 'challenge_invalid');
      expect(refusal.retryable, isFalse);
      expect((await h.load())!.receiptSecret, _secret);
      h.answer = (_) async => _reply('unknown', 404);
      expect((await h.request(h.facade()) as ImmediateDeletionFailed).code, 'unknown');
      expect(h.secrets, 1);
      expect(h.operations, 1);
      expect(jsonDecode(h.sent.last.body), {'action': 'status', 'receipt_secret': _secret});
    });

    test('confirmed completion persists before retiring and invalidates all old handles', () async {
      final h = _Custody();
      final f = h.facade();
      await h.request(f);
      final old = (await f.restore(owner: 'uid-a'))!;
      h.answer = (_) async => _reply('completed');
      expect(await f.recover(old), isA<ImmediateDeletionCompleted>());
      final saved = (await h.load())!;
      expect(saved.phase, ImmediateDeletionPhase.completed);
      expect(saved.receiptSecret, isNull);
      expect(await f.restore(owner: 'uid-a'), isNull);
      final sent = h.sent.length;
      expect(await f.recover(old), isA<ImmediateDeletionFailed>());
      expect(h.sent.length, sent);
      final restart = h.facade();
      expect(await restart.restore(owner: 'uid-a'), isNull);
      expect(await h.request(restart), isA<ImmediateDeletionCompleted>());
      expect((await h.request(restart, secret: _secret) as ImmediateDeletionFailed).code, 'operation_closed');
      expect((await h.request(restart, secret: 'Z' * 43) as ImmediateDeletionFailed).code, 'operation_closed');
      expect(h.sent.length, sent);
    });

    for (final failure in ['before-write', 'after-write', 'readback', 'sanitize']) {
      test('completion $failure ambiguity is truthful and never deletes unresolved capability', () async {
        final h = _Custody();
        final f = h.facade();
        await h.request(f);
        final handle = (await f.restore(owner: 'uid-a'))!;
        h.answer = (_) async => _reply('completed');
        h.onWrite = (_, encoded) async {
          final m = jsonDecode(encoded);
          if (m['phase'] == 'completed' && m['receipt_secret'] != null) {
            if (failure == 'before-write') throw StateError('write');
            if (failure == 'after-write') h.throwAfterWrite = true;
            if (failure == 'readback') h.onRead = (_) async => throw StateError('read');
          }
          if (failure == 'sanitize' && m['receipt_secret'] == null) throw StateError('sanitize');
        };
        final result = await f.recover(handle);
        expect(result, failure == 'sanitize' ? isA<ImmediateDeletionCompleted>() : isA<ImmediateDeletionFailed>());
        h.onRead = null; h.onWrite = null; h.throwAfterWrite = false;
        final saved = (await h.load())!;
        expect(saved.receiptSecret, _secret);
        if (failure == 'before-write') {
          expect(saved.phase, ImmediateDeletionPhase.mayHaveBeenSent);
          expect(await f.recover(handle), isA<ImmediateDeletionCompleted>());
        } else {
          expect(saved.phase, ImmediateDeletionPhase.completed);
          expect(await h.facade().restore(owner: 'uid-a'), isNull);
          final count = h.sent.length;
          expect(await f.recover(handle), isA<ImmediateDeletionFailed>());
          expect(h.sent.length, count);
        }
      });
    }
  });

  group('coherent owner and lifecycle binding', () {
    for (final next in <String?>[null, 'uid-b', 'uid-a']) {
      test('preparation paused then logout/switch/same-UID relog $next never dispatches', () async {
        final h = _Custody();
        final arrived = Completer<void>(); final release = Completer<void>();
        h.prepare = () async { arrived.complete(); await release.future; };
        final result = h.request(h.facade());
        await arrived.future;
        h.transition(next);
        release.complete();
        expect(await result, isA<ImmediateDeletionFailed>());
        expect(h.sent, isEmpty);
      });

      test('old response and handles cannot publish after logout/switch/relog $next', () async {
        final h = _Custody(); final f = h.facade();
        await h.request(f);
        final handle = (await f.restore(owner: 'uid-a'))!;
        final arrived = Completer<void>(); final release = Completer<http.Response>();
        h.answer = (_) { arrived.complete(); return release.future; };
        final result = f.recover(handle);
        await arrived.future;
        h.transition(next);
        release.complete(_reply('completed'));
        expect(await result, isA<ImmediateDeletionFailed>());
        expect((await h.load())!.phase, ImmediateDeletionPhase.mayHaveBeenSent);
        final count = h.sent.length;
        expect(await f.recover(handle), isA<ImmediateDeletionFailed>());
        expect(h.sent.length, count);
      });
    }

    for (final latestAfterPrepare in [false, true]) {
      for (final transition in ['logout', 'same-UID-relogin', 'A-to-B-to-A']) {
        test('compatibility status first capture cannot adopt a new lifecycle after $transition (returns ${latestAfterPrepare ? 'new' : 'old'} snapshot)', () async {
          final h = _Custody(); final f = h.facade(latestAfterPrepare: latestAfterPrepare);
          await h.request(f);
          final sentBefore = h.sent.length;
          final arrived = Completer<void>(); final release = Completer<void>();
          var captures = 0;
          h.prepare = () async {
            if (++captures == 1) {
              arrived.complete();
              await release.future;
            }
          };
          h.answer = (_) async => _reply('completed');
          final result = f.status(receiptSecret: _secret);
          await arrived.future;
          if (transition == 'logout') {
            h.transition(null);
          } else if (transition == 'same-UID-relogin') {
            h.transition(null);
            h.transition('uid-a');
          } else {
            h.transition('uid-b');
            h.transition('uid-a');
          }
          release.complete();
          final outcome = await result;
          expect(h.sent.length, sentBefore,
              reason: 'the original status call must not send under a replacement session');
          expect(outcome, isA<ImmediateDeletionFailed>());
          expect(captures, 1, reason: 'status must retain its original coherent binding');
          final saved = (await h.load())!;
          expect(saved.phase, ImmediateDeletionPhase.mayHaveBeenSent);
          expect(saved.receiptSecret, _secret);
        });
      }
    }

    for (final next in <String?>[null, 'uid-b', 'uid-a']) {
      test('compatibility status paused receipt lookup rejects changed lifecycle $next', () async {
        final h = _Custody(); final f = h.facade();
        await h.request(f);
        final sentBefore = h.sent.length;
        final arrived = Completer<void>(); final release = Completer<void>();
        final pauseAt = h.reads + 1;
        h.onRead = (n) async {
          if (n == pauseAt) { arrived.complete(); await release.future; }
        };
        final result = f.status(receiptSecret: _secret);
        await arrived.future;
        h.transition(next);
        release.complete();
        expect(await result, isA<ImmediateDeletionFailed>());
        expect(h.sent.length, sentBefore);
        expect((await h.load())!.phase, ImmediateDeletionPhase.mayHaveBeenSent);
        expect((await h.load())!.receiptSecret, _secret);
      });
    }

    test('compatibility status unchanged owner/lifecycle polls matching custody without a JWT', () async {
      final h = _Custody(); final f = h.facade();
      await h.request(f);
      var captures = 0;
      h.prepare = () async { captures++; };
      expect(await f.status(receiptSecret: _secret), isA<ImmediateDeletionInProgress>());
      expect(captures, 1);
      expect(jsonDecode(h.sent.last.body), {'action': 'status', 'receipt_secret': _secret});
      expect(h.sent.last.headers.containsKey('Authorization'), isFalse);
    });

    test('B cannot open A; explicit signed-out selected recovery sends no JWT', () async {
      final h = _Custody(); final f = h.facade();
      await h.request(f);
      h.transition('uid-b');
      expect(await f.restore(owner: 'uid-a'), isNull);
      expect(h.sent.length, 1);
      h.transition(null);
      final selected = (await f.restore(owner: 'uid-a'))!;
      h.answer = (_) async => _reply('completed');
      expect(await f.recover(selected), isA<ImmediateDeletionCompleted>());
      expect(h.sent.last.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(h.sent.last.body), {'action': 'status', 'receipt_secret': _secret});
      expect((await h.load())!.receiptSecret, isNull);
    });

    test('opaque handle/store/binding/failure strings contain no capabilities or tokens', () async {
      final h = _Custody(); final f = h.facade();
      await h.request(f);
      final handle = (await f.restore(owner: 'uid-a'))!;
      final text = '${await h.load()} $handle ${const ImmediateDeletionBinding(owner: "uid-a", lifecycle: 1, bearerToken: "coherent-token")} ${const ImmediateDeletionFailed(_secret, retryable: true, code: "network")}';
      expect(text, isNot(contains(_secret)));
      expect(text, isNot(contains('coherent-token')));
    });
  });
}
