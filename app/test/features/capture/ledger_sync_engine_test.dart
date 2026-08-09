import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:money_companion/features/capture/services/ledger_sync_engine.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';

// ── Stubs ─────────────────────────────────────────────────────────────────────

class _StubPush implements LedgerPushAdapter {
  _StubPush({
    LedgerPushResult result = const LedgerPushResult(),
    bool throws = false,
  })  : _result = result,
        _throws = throws;

  final LedgerPushResult _result;
  final bool _throws;
  bool called = false;

  @override
  Future<LedgerPushResult> push() async {
    called = true;
    if (_throws) throw Exception('push error');
    return _result;
  }
}

class _StubPull implements LedgerPullAdapter {
  _StubPull({
    LedgerSyncResult result = const LedgerSyncResult(),
    bool throws = false,
  })  : _result = result,
        _throws = throws;

  final LedgerSyncResult _result;
  final bool _throws;
  bool called = false;

  @override
  Future<LedgerSyncResult> pull({SyncCursor? from, bool Function()? isAdmitted}) async {
    called = true;
    if (_throws) throw Exception('pull error');
    return _result;
  }
}

// ── Ordering probes ───────────────────────────────────────────────────────────

class _OrderedPush implements LedgerPushAdapter {
  _OrderedPush(this._log);
  final List<String> _log;

  @override
  Future<LedgerPushResult> push() async {
    _log.add('push');
    return const LedgerPushResult();
  }
}

class _OrderedPull implements LedgerPullAdapter {
  _OrderedPull(this._log);
  final List<String> _log;

  @override
  Future<LedgerSyncResult> pull({SyncCursor? from, bool Function()? isAdmitted}) async {
    _log.add('pull');
    return const LedgerSyncResult();
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

LedgerSyncEngine _engine({
  LedgerPushResult pushResult = const LedgerPushResult(),
  LedgerSyncResult pullResult = const LedgerSyncResult(),
  bool pushThrows = false,
  bool pullThrows = false,
}) =>
    LedgerSyncEngine(
      pushService: _StubPush(result: pushResult, throws: pushThrows),
      pullService: _StubPull(result: pullResult, throws: pullThrows),
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  test('sync calls push then pull', () async {
    final push = _StubPush(result: const LedgerPushResult(pushed: 1));
    final pull = _StubPull(result: const LedgerSyncResult(imported: 2));
    final engine = LedgerSyncEngine(pushService: push, pullService: pull);

    await engine.sync();

    expect(push.called, isTrue);
    expect(pull.called, isTrue);
  });

  test('pull still runs when push throws', () async {
    final push = _StubPush(throws: true);
    final pull = _StubPull(result: const LedgerSyncResult(imported: 1));
    final engine = LedgerSyncEngine(pushService: push, pullService: pull);

    await engine.sync();

    expect(push.called, isTrue);
    expect(pull.called, isTrue);
  });

  test('sync completes without throw when pull throws', () async {
    await expectLater(_engine(pullThrows: true).sync(), completes);
  });

  test('sync completes without throw when both throw', () async {
    await expectLater(
      _engine(pushThrows: true, pullThrows: true).sync(),
      completes,
    );
  });

  test('push-before-pull ordering is enforced', () async {
    final callOrder = <String>[];
    await LedgerSyncEngine(
      pushService: _OrderedPush(callOrder),
      pullService: _OrderedPull(callOrder),
    ).sync();
    expect(callOrder, ['push', 'pull']);
  });

  test('sync with no-op services completes', () async {
    await expectLater(_engine().sync(), completes);
  });

  test('sync handles push conflict result gracefully', () async {
    await expectLater(
      _engine(
        pushResult: const LedgerPushResult(pushed: 0, conflicts: 1),
        pullResult: const LedgerSyncResult(updated: 1),
      ).sync(),
      completes,
    );
  });
}
