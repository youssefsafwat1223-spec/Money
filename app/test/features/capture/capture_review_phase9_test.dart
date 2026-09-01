/// PHASE 9 — review states, notification identity, and action safety.
///
/// The properties worth testing here are the ones that fail silently in
/// production: a notification that stacks instead of updating, an SMS body that
/// reaches a lock screen, a stale tap that resurrects an old decision over a
/// newer user edit.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/capture_review_state.dart';
import 'package:money_companion/features/capture/services/capture_review_notification.dart';

void main() {
  group('review states distinguish the reasons a capture is pending', () {
    test('every approved state exists', () {
      expect(CaptureReviewState.values.map((e) => e.name).toSet(), {
        'proven',
        'pendingAi',
        'offlinePending',
        'amountConflict',
        'currencyConflict',
        'directionAmbiguous',
        'directionConflict',
        'categoryAmbiguous',
        'rejectedNotTransaction',
        'retryableFailure',
      });
    });

    test('transient states are not decisions and ask nothing of the user', () {
      for (final s in const [
        CaptureReviewState.pendingAi,
        CaptureReviewState.offlinePending,
        CaptureReviewState.retryableFailure,
      ]) {
        expect(s.isTransient, isTrue);
        expect(s.needsUserDecision, isFalse, reason: '$s');
        expect(s.isTerminal, isFalse, reason: '$s');
      }
    });

    test('conflict states ask the user a question', () {
      for (final s in const [
        CaptureReviewState.amountConflict,
        CaptureReviewState.currencyConflict,
        CaptureReviewState.directionAmbiguous,
        CaptureReviewState.directionConflict,
        CaptureReviewState.categoryAmbiguous,
      ]) {
        expect(s.needsUserDecision, isTrue, reason: '$s');
        expect(s.isTransient, isFalse, reason: '$s');
      }
    });

    test('a deterministic ambiguity is NOT retryable', () {
      // Re-running the model on an ambiguity the deterministic layer refused
      // would spend money to be refused again: the ambiguity is a property of
      // the message, not of the attempt.
      for (final s in const [
        CaptureReviewState.amountConflict,
        CaptureReviewState.directionConflict,
        CaptureReviewState.directionAmbiguous,
      ]) {
        expect(s.isRetryable, isFalse, reason: '$s');
      }
      expect(CaptureReviewState.retryableFailure.isRetryable, isTrue);
      expect(CaptureReviewState.offlinePending.isRetryable, isTrue);
    });

    test('proven is terminal but still not auto-committed', () {
      // Phase 11 is blocked, so proven surfaces for confirmation.
      expect(CaptureReviewState.proven.isTerminal, isTrue);
      expect(CaptureReviewNotification.shouldNotify(CaptureReviewState.proven),
          isTrue);
    });
  });

  group('notification identity is stable per capture work item', () {
    test('the same capture always maps to the same id', () {
      expect(CaptureReviewNotification.notificationIdFor('uuid-1'),
          CaptureReviewNotification.notificationIdFor('uuid-1'));
    });

    test('different captures get different ids', () {
      expect(CaptureReviewNotification.notificationIdFor('uuid-1'),
          isNot(CaptureReviewNotification.notificationIdFor('uuid-2')));
    });

    test('pending → resolved REPLACES rather than stacks', () {
      // Same capture, two lifecycle points, one notification row. Deriving the
      // id from a transaction id would break here: a pending capture has no
      // transaction yet.
      const uuid = 'uuid-1';
      final whilePending = CaptureReviewNotification.notificationIdFor(uuid);
      final whenProven = CaptureReviewNotification.notificationIdFor(uuid);
      expect(whilePending, whenProven);
    });

    test('ids are positive and within the platform range', () {
      for (final u in const ['a', 'uuid-1', 'AAAAAAAAAAAAAAAA', '👨‍👩‍👧‍👦']) {
        final id = CaptureReviewNotification.notificationIdFor(u);
        expect(id, greaterThanOrEqualTo(0));
        expect(id, lessThanOrEqualTo(0x7FFFFFFF));
      }
    });
  });

  group('transient states do not interrupt the user', () {
    test('pending / offline / retryable are not notified', () {
      for (final s in const [
        CaptureReviewState.pendingAi,
        CaptureReviewState.offlinePending,
        CaptureReviewState.retryableFailure,
      ]) {
        expect(CaptureReviewNotification.shouldNotify(s), isFalse, reason: '$s');
      }
    });

    test('a non-transaction is not notified', () {
      expect(
          CaptureReviewNotification.shouldNotify(
              CaptureReviewState.rejectedNotTransaction),
          isFalse);
    });
  });

  group('privacy — no raw SMS, and less still on a lock screen', () {
    const sms = 'شراء بمبلغ 45.00 ر.س لدى مطعم البيك بطاقة 1234';

    test('no notification body contains the message', () {
      for (final s in CaptureReviewState.values) {
        final body =
            CaptureReviewNotification.bodyFor(s, amountLabel: '45.00 ر.س');
        expect(body.contains(sms), isFalse);
        expect(body.contains('1234'), isFalse,
            reason: 'card digits must never reach a notification');
        expect(body.contains('مطعم البيك'), isFalse,
            reason: 'merchant must not appear');
      }
    });

    test('the lock-screen variant names no amount at all', () {
      for (final s in CaptureReviewState.values) {
        final body = CaptureReviewNotification.bodyFor(
          s,
          amountLabel: '45.00 ر.س',
          lockScreenSafe: true,
        );
        expect(body.contains('45.00'), isFalse,
            reason: 'a stranger glancing at a locked screen learns nothing '
                'about this person\'s finances');
      }
    });

    test('an absent amount does not produce a dangling label', () {
      final body = CaptureReviewNotification.bodyFor(CaptureReviewState.proven);
      expect(body.contains('null'), isFalse);
    });
  });

  group('notification actions carry no authority', () {
    test('an action request holds no database handle — it is inert data', () {
      const req = CaptureNotificationActionRequest(
        captureUuid: 'u1',
        action: CaptureNotificationAction.confirm,
        postedAtRevision: 3,
      );
      // Its whole surface is identity + intent + the revision it was posted
      // against. There is nothing here that could mutate anything.
      expect(req.captureUuid, 'u1');
      expect(req.action, CaptureNotificationAction.confirm);
      expect(req.postedAtRevision, 3);
    });

    test('a STALE action is detectable and must lose', () {
      const req = CaptureNotificationActionRequest(
        captureUuid: 'u1',
        action: CaptureNotificationAction.confirm,
        postedAtRevision: 3,
      );
      expect(req.isStaleAgainst(4), isTrue,
          reason: 'the user edited after this banner was posted');
      expect(req.isStaleAgainst(3), isFalse);
    });

    test('a notification posted long ago cannot overwrite newer user intent',
        () {
      const req = CaptureNotificationActionRequest(
        captureUuid: 'u1',
        action: CaptureNotificationAction.confirm,
        postedAtRevision: 1,
      );
      expect(req.isStaleAgainst(7), isTrue);
    });
  });

  group('instrumentation records real actions only', () {
    test('an accepted outcome records no corrected fields', () {
      const o = CaptureReviewOutcome(
        captureUuid: 'u1',
        state: CaptureReviewState.proven,
        action: CaptureReviewAction.accepted,
      );
      expect(o.correctedFields, isEmpty);
      expect(o.correctedDirection, isFalse);
    });

    test('a direction correction is called out specifically', () {
      // A wrong direction is a wrong-SIGNED transaction — the most damaging
      // single-field error the system can make.
      const o = CaptureReviewOutcome(
        captureUuid: 'u1',
        state: CaptureReviewState.directionAmbiguous,
        action: CaptureReviewAction.corrected,
        correctedFields: {CorrectedField.direction},
      );
      expect(o.correctedDirection, isTrue);
      expect(o.toTelemetry()['corrected_direction'], isTrue);
    });

    test('telemetry contains no free text by construction', () {
      const o = CaptureReviewOutcome(
        captureUuid: 'u1',
        state: CaptureReviewState.amountConflict,
        action: CaptureReviewAction.corrected,
        correctedFields: {CorrectedField.amount, CorrectedField.merchant},
      );
      final t = o.toTelemetry();
      expect(t.keys.toSet(), {
        'capture_uuid',
        'review_state',
        'review_action',
        'corrected_fields',
        'corrected_direction',
      });
      // Every value is an id, an enum name or a bool. No amount, no merchant
      // string, no message text can be carried here even by mistake.
      expect(t['corrected_fields'], ['amount', 'merchant']);
    });

    test('every corrected field is representable', () {
      expect(CorrectedField.values.map((e) => e.name).toSet(), {
        'amount',
        'currency',
        'direction',
        'type',
        'category',
        'merchant',
      });
    });
  });
}
