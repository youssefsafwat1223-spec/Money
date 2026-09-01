// COUPONS Phase 3 — the device's click path, against a REAL database.
//
// One property dominates: A TRACKING FAILURE MUST NEVER STOP SOMEONE USING A
// COUPON. Tracking is how we earn; reaching the offer is the product. Trading
// the second for the first loses both — the user misses the discount and we
// earn nothing anyway.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/coupons/affiliate_click_gateway.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

CouponOffer _offer({String? url = 'https://merchant.test/offer'}) => CouponOffer(
      id: 'coupon-1',
      slug: 'c',
      partnerName: 'P',
      titleAr: 'ع',
      descriptionAr: 'و',
      redemptionType: CouponRedemptionType.link,
      partnerUrl: url,
      category: const CouponCategory(key: 'k', labelAr: 'ك'),
      validFrom: DateTime.utc(2026, 1, 1),
      merchantId: 'm-1',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    await db.initialize();
  });
  tearDown(() => db.close());

  AffiliateClickGateway gateway({
    required Future<Map<String, Object?>?> Function(Map<String, Object?>) prepare,
    bool enabled = true,
  }) =>
      AffiliateClickGateway(
        database: db,
        prepareClick: prepare,
        trackingEnabled: () => enabled,
      );

  final trackedOk = <String, Object?>{
    'tracked': true,
    'url': 'https://merchant.test/offer?subid=abc',
    'click_id': 'click-abc',
    'claim_token': 'token-abc',
  };

  group('the user always reaches the offer', () {
    test('a server ERROR falls back to the plain URL', () async {
      final g = gateway(prepare: (_) async => throw const SocketException('down'));
      final r = await g.open(_offer());
      expect(r.outcome, ClickOutcome.untracked);
      expect(r.url, 'https://merchant.test/offer');
    });

    test('a null response falls back', () async {
      final r = await gateway(prepare: (_) async => null).open(_offer());
      expect(r.outcome, ClickOutcome.untracked);
      expect(r.url, isNotNull);
    });

    test('the flag being off makes NO request at all', () async {
      var called = false;
      final g = gateway(enabled: false, prepare: (_) async {
        called = true;
        return trackedOk;
      });
      final r = await g.open(_offer());
      expect(called, isFalse, reason: 'a disabled build must not call the endpoint');
      expect(r.outcome, ClickOutcome.untracked);
      expect(r.url, 'https://merchant.test/offer');
    });

    test('a malformed tracked response falls back rather than opening it', () async {
      for (final bad in [
        {'tracked': true, 'url': 'http://insecure.test', 'click_id': 'a', 'claim_token': 'b'},
        {'tracked': true, 'url': 'https://ok.test', 'click_id': 42, 'claim_token': 'b'},
        {'tracked': true, 'url': null, 'click_id': 'a', 'claim_token': 'b'},
      ]) {
        final r = await gateway(prepare: (_) async => bad).open(_offer());
        expect(r.outcome, ClickOutcome.untracked, reason: bad.toString());
        expect(r.url, 'https://merchant.test/offer');
      }
    });

    test('an http URL from the server is NEVER opened', () async {
      // A tracked click that downgrades the connection is worse than an
      // untracked one: the user gets neither privacy nor the offer safely.
      final r = await gateway(prepare: (_) async => {
            'tracked': false, 'url': 'http://insecure.test/x',
          }).open(_offer());
      expect(r.url, 'https://merchant.test/offer');
    });

    test('an offer with no URL is unavailable, not a crash', () async {
      final r = await gateway(prepare: (_) async => trackedOk).open(_offer(url: null));
      expect(r.outcome, ClickOutcome.unavailable);
      expect(r.url, isNull);
    });
  });

  group('the receipt is the device half of the click', () {
    test('a tracked click stores its token before returning', () async {
      // If the app died between launching the browser and writing the receipt,
      // the click would exist server-side with no token on the device —
      // permanently unclaimable, and the user would never get credit.
      final g = gateway(prepare: (_) async => trackedOk);
      final r = await g.open(_offer());
      expect(r.outcome, ClickOutcome.tracked);
      expect(r.clickId, 'click-abc');

      final pending = await g.pendingReceipts();
      expect(pending.single.clickId, 'click-abc');
      expect(pending.single.claimToken, 'token-abc',
          reason: 'the PLAINTEXT token lives only here');
      expect(pending.single.couponId, 'coupon-1');
      expect(pending.single.merchantId, 'm-1');
    });

    test('a second launch of the same click does not duplicate', () async {
      final g = gateway(prepare: (_) async => trackedOk);
      await g.open(_offer());
      await g.open(_offer());
      expect((await g.pendingReceipts()).length, 1);
    });

    test('a resolved click leaves the pending set', () async {
      final g = gateway(prepare: (_) async => trackedOk);
      await g.open(_offer());
      await g.recordStatus('click-abc', 'confirmed');
      expect(await g.pendingReceipts(), isEmpty);
    });

    test('expired receipts are pruned — they hold a token', () async {
      // An expired receipt is a credential that can no longer be used for
      // anything, so keeping it is retention with no purpose.
      final g = gateway(prepare: (_) async => trackedOk);
      await g.open(_offer());
      await db.customUpdate(
        "UPDATE affiliate_click_receipts SET expires_at = '2020-01-01T00:00:00.000Z';",
      );
      expect(await g.pendingReceipts(), isEmpty,
          reason: 'an expired receipt is never polled');
      expect(await g.pruneExpired(), 1);
      final rows =
          await db.customSelect('SELECT COUNT(*) AS n FROM affiliate_click_receipts;').get();
      expect(rows.single.read<int>('n'), 0);
    });
  });

  test('the gateway sends no identity of any kind', () async {
    // The endpoint authenticates the caller and then deliberately forgets them.
    // The body must not help it remember.
    Map<String, Object?>? sent;
    final g = gateway(prepare: (body) async {
      sent = body;
      return trackedOk;
    });
    await g.open(_offer(), surface: 'offers_screen');
    expect(sent!.keys.toSet(), {'coupon_id', 'surface'});
    for (final forbidden in ['user_id', 'install_id', 'device_id', 'email']) {
      expect(sent!.containsKey(forbidden), isFalse);
    }
  });
}
