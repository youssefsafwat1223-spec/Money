import 'package:money_companion/core/session/remove_data_flow.dart';

/// Records the §4.4 barrier calls the removal flow makes on the native queue.
class FakeRemoveBarrier implements RemoveDataBarrier {
  FakeRemoveBarrier(this.calls);
  final List<String> calls;
  String? pending;
  bool failFinish = false;
  Future<void> Function(String call)? onCall;

  Future<void> _rec(String c) async {
    calls.add(c);
    await onCall?.call(c);
  }

  @override
  Future<void> begin(String uid) async {
    await _rec('begin:$uid');
    pending = uid;
  }

  @override
  Future<String?> pendingUid() async => pending;

  @override
  Future<void> finish(String uid) async {
    await _rec('finish:$uid');
    if (failFinish) throw const RemoveDataIncompleteException();
    pending = null;
  }
}
