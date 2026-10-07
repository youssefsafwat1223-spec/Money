import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/features/capture/services/capture_import_ports.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

/// One queue item as the native v3 store models it: owner state, hint, origin.
class FakeQueueItem {
  FakeQueueItem(
    this.id, {
    this.text = 'text',
    this.sender = 'SNB',
    this.ownerUid,
    this.hint,
    this.origin,
    this.localOnly = false,
    this.reviewState,
    this.receivedAt,
    this.status = 'sent',
  });

  final String id;
  final String text;
  final String? sender;
  String? ownerUid; // non-null: stamped
  String? hint; // unbound only
  final String? origin; // 'legacy_v2'
  bool localOnly;
  String? reviewState;
  final DateTime? receivedAt;

  /// Native lifecycle status; `sent` means the native side already notified.
  final String status;

  bool get unbound => ownerUid == null;
}

/// Models the CAP-6a native queue rules the Dart side relies on: peek returns
/// the ACTIVE owner's stamped items only, the unbound summary is keyed by hint,
/// claim/discard are a CAS, and legacy resolution touches only unbound legacy
/// items. A hint is a plain `h:<uid>` string here; the real one is an HMAC.
class FakeNativeCaptureQueue implements CaptureImportQueue {
  final List<FakeQueueItem> items = [];
  CaptureOwnerRecord? owner;
  final summaryUids = <String>[];
  var claimCalls = 0;
  var discardCalls = 0;
  var resolveCalls = 0;
  List<String> lastConsumed = const [];
  List<String> lastSuspected = const [];

  static String hintFor(String uid) => 'h:$uid';

  void setOwner(String? uid, {int generation = 1}) => owner = uid == null
      ? null
      : CaptureOwnerRecord(
          uid: uid, uidHash: hintFor(uid), generation: generation);

  @override
  Future<List<SharedCapturedMessage>> peek() async => [
        for (final i in items)
          if (owner != null && i.ownerUid == owner!.uid)
            SharedCapturedMessage(
              id: i.id,
              text: i.text,
              sender: i.sender,
              source: CapturedMessageSource.iosShortcut,
              receivedAt: i.receivedAt,
              status: i.status,
              ownerUid: i.ownerUid,
              localOnly: i.localOnly,
            ),
      ];

  @override
  Future<bool> acknowledge(String payloadId) async {
    final before = items.length;
    items.removeWhere((i) => i.id == payloadId);
    return items.length < before;
  }

  @override
  Future<CaptureOwnerRecord?> getOwner() async => owner;

  @override
  Future<UnboundCaptureSummary> unboundSummary(String uid) async {
    summaryUids.add(uid);
    final mine = items.where((i) => i.unbound && i.hint == hintFor(uid));
    return UnboundCaptureSummary(
      ids: [for (final i in mine) i.id],
      senders: {
        for (final i in mine)
          if (i.sender != null) i.sender!
      }.toList()
        ..sort(),
    );
  }

  CaptureClaimResult _cas(
    String uid,
    int generation,
    String replicaOwnerUid,
    String sessionUid,
    List<String> ids,
    void Function(List<FakeQueueItem>) apply,
  ) {
    if (owner == null ||
        owner!.uid != uid ||
        owner!.generation != generation ||
        replicaOwnerUid != uid ||
        sessionUid != uid) {
      return const CaptureClaimResult(CaptureClaimStatus.ownerMismatch, 0);
    }
    final picked = <FakeQueueItem>[];
    for (final id in ids) {
      final matches =
          items.where((i) => i.id == id && i.unbound && i.hint == hintFor(uid));
      if (matches.isEmpty) {
        return const CaptureClaimResult(CaptureClaimStatus.stale, 0);
      }
      picked.add(matches.first);
    }
    apply(picked);
    return CaptureClaimResult(CaptureClaimStatus.applied, picked.length);
  }

  @override
  Future<CaptureClaimResult> claim({
    required String uid,
    required int generation,
    required String replicaOwnerUid,
    required String sessionUid,
    required List<String> ids,
  }) async {
    claimCalls++;
    return _cas(uid, generation, replicaOwnerUid, sessionUid, ids, (picked) {
      for (final i in picked) {
        i.ownerUid = uid;
        i.hint = null;
        i.localOnly = true;
      }
    });
  }

  @override
  Future<CaptureClaimResult> discard({
    required String uid,
    required int generation,
    required String replicaOwnerUid,
    required String sessionUid,
    required List<String> ids,
  }) async {
    discardCalls++;
    return _cas(uid, generation, replicaOwnerUid, sessionUid, ids, (picked) {
      items.removeWhere(picked.contains);
    });
  }

  @override
  Future<int> resolveLegacy({
    List<String> consumedIds = const [],
    List<String> suspectedIds = const [],
  }) async {
    resolveCalls++;
    lastConsumed = consumedIds;
    lastSuspected = suspectedIds;
    bool legacy(FakeQueueItem i) => i.origin == 'legacy_v2' && i.unbound;
    final before = items.length;
    items.removeWhere((i) => legacy(i) && consumedIds.contains(i.id));
    for (final i in items) {
      if (legacy(i) && suspectedIds.contains(i.id)) {
        i.reviewState = 'suspected_already_imported';
      }
    }
    return before - items.length;
  }
}
