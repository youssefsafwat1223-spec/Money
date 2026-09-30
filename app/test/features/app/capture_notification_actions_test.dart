import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/app/capture_notification_actions.dart';

void main() {
  group('captureRouteFor', () {
    test('smart_inbox: marker never becomes a transaction route', () {
      expect(captureRouteFor(transactionId: 'smart_inbox:local_capture:p1'),
          '/smart-inbox');
      expect(
          captureRouteFor(
              payloadTransactionId: 'smart_inbox:local_capture:p1'),
          '/smart-inbox');
    });

    test('rejected: goes to the Smart Inbox', () {
      expect(captureRouteFor(transactionId: 'rejected:p1'), '/smart-inbox');
      expect(
          captureRouteFor(payloadTransactionId: 'rejected:p1'), '/smart-inbox');
    });

    test('real ids route to the transaction', () {
      expect(captureRouteFor(transactionId: 'tx1'), '/transaction/tx1');
      expect(captureRouteFor(payloadTransactionId: 'tx2'), '/transaction/tx2');
      expect(
          captureRouteFor(
              transactionId: 'rejected:p1', payloadTransactionId: 'tx3'),
          '/transaction/tx3');
    });

    test('needs_review type wins over a transaction id', () {
      expect(captureRouteFor(type: 'needs_review', transactionId: 'tx1'),
          '/smart-inbox');
      expect(
          captureRouteFor(type: 'suspicious_duplicate', transactionId: 'tx1'),
          '/smart-inbox');
    });

    test('nothing known falls back to the Smart Inbox', () {
      expect(captureRouteFor(), '/smart-inbox');
    });
  });

  test('smartInboxItemIdFromMarker', () {
    expect(smartInboxItemIdFromMarker('smart_inbox:local_capture:p1'),
        'local_capture:p1');
    expect(smartInboxItemIdFromMarker('tx1'), isNull);
    expect(smartInboxItemIdFromMarker('smart_inbox:'), isNull);
    expect(smartInboxItemIdFromMarker(null), isNull);
  });

  group('handleCaptureNotificationAction', () {
    late List<String> log;
    late bool saved;
    late bool granted;

    Future<void> run(String action, {String? marker}) =>
        handleCaptureNotificationAction(
          action: action,
          smartInboxMarker: marker,
          showSmartInbox: () => log.add('inbox'),
          openManualSheet: () async {
            log.add('manual');
            return saved;
          },
          resolveItem: (id) async => log.add('resolve:$id'),
          isSmartAnalysisGranted: () async => granted,
          openConsentSheet: () async {
            log.add('consent');
            return true;
          },
          openPrivacy: () => log.add('privacy'),
        );

    setUp(() {
      log = [];
      saved = false;
      granted = false;
    });

    test('add manually opens the sheet and resolves only when saved',
        () async {
      saved = true;
      await run(kActionAddManually, marker: 'smart_inbox:local_capture:p1');
      expect(log, ['inbox', 'manual', 'resolve:local_capture:p1']);
    });

    test('add manually without a save resolves nothing', () async {
      await run(kActionAddManually, marker: 'smart_inbox:local_capture:p1');
      expect(log, ['inbox', 'manual']);
    });

    test('add manually with no smart inbox marker resolves nothing', () async {
      saved = true;
      await run(kActionAddManually, marker: 'rejected:p1');
      expect(log, ['inbox', 'manual']);
    });

    test('enable with consent off opens the consent sheet', () async {
      await run(kActionEnableSmartAnalysis);
      expect(log, ['consent']);
    });

    test('enable with consent on routes to privacy', () async {
      granted = true;
      await run(kActionEnableSmartAnalysis);
      expect(log, ['privacy']);
    });
  });
}
