// CAP-5 / BL-2 (§4.3) + A2: the "N bank messages were received while you were
// signed out" prompt. Hint gating, CAS failure without mutation, local-only
// binding. The native layer is a fake that models the CAP-6a rules.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/unbound_capture_prompt_service.dart';

import 'fake_native_capture_queue.dart';

void main() {
  late FakeNativeCaptureQueue queue;
  String? session;
  String? replica;
  var enabled = true;

  UnboundCapturePromptService service() => UnboundCapturePromptService(
        queue: queue,
        sessionUid: () => session,
        replicaOwnerUid: () async => replica,
        isEnabled: () => enabled,
      );

  FakeQueueItem unbound(String id, String? hintUid, {String sender = 'SNB'}) =>
      FakeQueueItem(id,
          sender: sender,
          hint:
              hintUid == null ? null : FakeNativeCaptureQueue.hintFor(hintUid));

  setUp(() {
    queue = FakeNativeCaptureQueue()..setOwner('user-A');
    session = 'user-A';
    replica = 'user-A';
    enabled = true;
  });

  group('offer (hint gating, A2)', () {
    test('shows only a count and the senders, when hint == current uid',
        () async {
      queue.items.addAll([
        unbound('1', 'user-A', sender: 'SNB'),
        unbound('2', 'user-A', sender: 'RAJHI'),
        unbound('3', 'user-A', sender: 'SNB'),
      ]);

      final offer = await service().check();

      expect(offer, isNotNull);
      expect(offer!.count, 3);
      expect(offer.senders, ['RAJHI', 'SNB']);
    });

    test(
        'hint is ANOTHER uid: no prompt, and only the session uid is asked about',
        () async {
      queue.items.add(unbound('1', 'user-A'));
      queue.setOwner('user-B');
      session = 'user-B';
      replica = 'user-B';

      expect(await service().check(), isNull);
      expect(queue.summaryUids, ['user-B'],
          reason: "A's hint is never looked up on behalf of B");
    });

    test('no hint (legacy / transition / no admitted user): no prompt',
        () async {
      queue.items.addAll([unbound('1', null), unbound('2', null)]);
      expect(await service().check(), isNull);
    });

    test('owner record, replica owner and session must be the same uid',
        () async {
      queue.items.add(unbound('1', 'user-A'));

      queue.setOwner('user-B');
      expect(await service().check(), isNull, reason: 'owner record is B');
      queue.setOwner('user-A');
      replica = 'user-B';
      expect(await service().check(), isNull, reason: 'replica owner is B');
      replica = 'user-A';
      session = null;
      expect(await service().check(), isNull, reason: 'no session');
      queue.setOwner(null);
      session = 'user-A';
      expect(await service().check(), isNull, reason: 'no owner record');
      expect(queue.summaryUids, isEmpty, reason: 'native not even asked');
    });

    test('flag off: no prompt', () async {
      queue.items.add(unbound('1', 'user-A'));
      enabled = false;
      expect(await service().check(), isNull);
      expect(queue.summaryUids, isEmpty);
    });
  });

  group('Add them to my account', () {
    test('binds the snapshot: stamped to the uid, local-only, hint cleared',
        () async {
      queue.items.addAll([unbound('1', 'user-A'), unbound('2', 'user-A')]);
      final svc = service();

      final result = await svc.add((await svc.check())!);

      expect(result, UnboundCaptureChoice.applied);
      expect(queue.items.every((i) => i.ownerUid == 'user-A'), isTrue);
      expect(queue.items.every((i) => i.localOnly), isTrue,
          reason: 'never uploaded, never AI');
      expect(queue.items.every((i) => i.hint == null), isTrue);
    });

    test('an item changed since the prompt: CAS fails, NOTHING is mutated',
        () async {
      queue.items.addAll([unbound('1', 'user-A'), unbound('2', 'user-A')]);
      final svc = service();
      final offer = (await svc.check())!;
      queue.items.removeWhere((i) => i.id == '2'); // discarded elsewhere

      expect(await svc.add(offer), UnboundCaptureChoice.changed);
      expect(queue.items.single.ownerUid, isNull);
      expect(queue.items.single.localOnly, isFalse);
    });

    test('account switch after the prompt was built: refused, nothing bound',
        () async {
      queue.items.add(unbound('1', 'user-A'));
      final svc = service();
      final offer = (await svc.check())!;
      // A -> B while the sheet was open.
      queue.setOwner('user-B', generation: 2);
      session = 'user-B';
      replica = 'user-B';

      expect(await svc.add(offer), UnboundCaptureChoice.refused);
      expect(await svc.discard(offer), UnboundCaptureChoice.refused);
      expect(queue.items.single.ownerUid, isNull, reason: 'not bound to B');
      expect(queue.items, hasLength(1), reason: 'not discarded either');
    });

    test('owner generation moved on (sign-out/in): refused, nothing bound',
        () async {
      queue.items.add(unbound('1', 'user-A'));
      final svc = service();
      final offer = (await svc.check())!;
      queue.setOwner('user-A', generation: 2);

      expect(await svc.add(offer), UnboundCaptureChoice.refused);
      expect(queue.items.single.ownerUid, isNull);
    });
  });

  group('Discard them', () {
    test('deletes exactly the snapshot', () async {
      queue.items.addAll([
        unbound('1', 'user-A'),
        unbound('2', 'user-A'),
        unbound('3', 'user-B'),
        unbound('4', null),
      ]);
      final svc = service();

      expect(await svc.discard((await svc.check())!),
          UnboundCaptureChoice.applied);

      expect(queue.items.map((i) => i.id), ['3', '4'],
          reason: "another uid's and hint-less items are untouched");
    });

    test('CAS failure deletes nothing', () async {
      queue.items.addAll([unbound('1', 'user-A'), unbound('2', 'user-A')]);
      final svc = service();
      final offer = (await svc.check())!;
      queue.items.firstWhere((i) => i.id == '2').hint =
          FakeNativeCaptureQueue.hintFor('user-B');

      expect(await svc.discard(offer), UnboundCaptureChoice.changed);
      expect(queue.items, hasLength(2));
    });
  });
}
