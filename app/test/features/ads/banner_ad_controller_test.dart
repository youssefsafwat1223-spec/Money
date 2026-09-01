import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ad_controller.dart';

/// The banner lifecycle, without a platform channel.
///
/// The properties these pin are the ones that cost money or trust when they
/// break: exactly one request per mount, no retry storm, a slot that never
/// shrinks under a finger, and a failure that is completely invisible.

class _FakeLoader implements BannerAdLoader {
  _FakeLoader({
    this.height = 60,
    this.succeeds = true,
    this.fireImpression = false,
  });

  final int? height;
  final bool succeeds;
  final bool fireImpression;

  int resolveCalls = 0;
  int loadCalls = 0;
  int disposeCalls = 0;
  int? lastWidth;
  int? lastHeight;
  String? lastUnitId;
  final Object _ad = Object();

  @override
  Object? get loadedAd => succeeds ? _ad : null;

  @override
  Future<int?> resolveHeight(int widthPx) async {
    resolveCalls++;
    return height;
  }

  @override
  Future<bool> load({
    required String adUnitId,
    required int widthPx,
    required int heightPx,
    VoidCallback? onImpression,
  }) async {
    loadCalls++;
    lastUnitId = adUnitId;
    lastWidth = widthPx;
    lastHeight = heightPx;
    if (succeeds && fireImpression) onImpression?.call();
    return succeeds;
  }

  @override
  void dispose() => disposeCalls++;
}

BannerAdController _controller(
  _FakeLoader loader, {
  void Function(String, String)? onEvent,
  Duration throttle = const Duration(seconds: 30),
  DateTime Function()? clock,
}) =>
    BannerAdController(
      placement: AdPlacement.transactionsList,
      loader: loader,
      onEvent: onEvent,
      minimumRequestInterval: throttle,
      clock: clock,
    );

void main() {
  setUp(BannerAdController.resetThrottleForTest);

  test('a successful load produces a slot with the resolved height', () async {
    final loader = _FakeLoader(height: 72);
    final c = _controller(loader);

    expect(c.status, BannerAdStatus.idle);
    expect(c.heightPx, isNull, reason: 'no height before an ad exists');

    await c.request(adUnitId: 'unit', widthPx: 400);

    expect(c.status, BannerAdStatus.loaded);
    expect(c.heightPx, 72);
    expect(c.ad, isNotNull);
    expect(loader.lastWidth, 400);
    expect(loader.lastHeight, 72);
    expect(loader.lastUnitId, 'unit');
  });

  test('a failed load is completely invisible — no slot, no height', () async {
    final c = _controller(_FakeLoader(succeeds: false));
    await c.request(adUnitId: 'unit', widthPx: 400);

    // The whole point of loading BEFORE reserving: a no-fill leaves nothing
    // behind to collapse, so no content ever moves.
    expect(c.status, BannerAdStatus.failed);
    expect(c.heightPx, isNull);
    expect(c.ad, isNull);
  });

  test('a null adaptive height falls back to the standard 50dp banner',
      () async {
    final loader = _FakeLoader(height: null);
    final c = _controller(loader);
    await c.request(adUnitId: 'unit', widthPx: 400);

    // Refusing here would silently disable the placement on whichever platform
    // returned null, which is a much worse failure than a shorter ad.
    expect(loader.lastHeight, 50);
    expect(c.heightPx, 50);
  });

  test('a second request on the same controller is ignored', () async {
    final loader = _FakeLoader();
    final c = _controller(loader);
    await c.request(adUnitId: 'unit', widthPx: 400);
    await c.request(adUnitId: 'unit', widthPx: 400);
    await c.request(adUnitId: 'unit', widthPx: 400);

    // One mount, one request. A rebuild must never buy another ad.
    expect(loader.loadCalls, 1);
    expect(loader.resolveCalls, 1);
  });

  test('a width below the narrowest standard banner is refused', () async {
    final loader = _FakeLoader();
    final c = _controller(loader);
    await c.request(adUnitId: 'unit', widthPx: 300);

    expect(c.status, BannerAdStatus.failed);
    expect(loader.loadCalls, 0, reason: 'nothing is requested at all');
    expect(loader.resolveCalls, 0);
  });

  test('exactly 320 is allowed — the boundary is inclusive', () async {
    final loader = _FakeLoader();
    final c = _controller(loader);
    await c.request(adUnitId: 'unit', widthPx: 320);
    expect(loader.loadCalls, 1);
  });

  test('a remount inside the throttle window does not request again', () async {
    var now = DateTime(2026, 9, 1, 12);
    final first = _FakeLoader();
    await _controller(first, clock: () => now)
        .request(adUnitId: 'unit', widthPx: 400);
    expect(first.loadCalls, 1);

    // Flicking to another tab and straight back: a new controller, but the
    // throttle is per PLACEMENT and survives the unmount, because the unmount
    // is the very event it exists to absorb.
    now = now.add(const Duration(seconds: 5));
    final second = _FakeLoader();
    final c2 = _controller(second, clock: () => now);
    await c2.request(adUnitId: 'unit', widthPx: 400);

    expect(second.loadCalls, 0);
    expect(c2.status, BannerAdStatus.failed);
  });

  test('once the throttle window passes, a remount may request again',
      () async {
    var now = DateTime(2026, 9, 1, 12);
    await _controller(_FakeLoader(), clock: () => now)
        .request(adUnitId: 'unit', widthPx: 400);

    now = now.add(const Duration(seconds: 31));
    final later = _FakeLoader();
    await _controller(later, clock: () => now)
        .request(adUnitId: 'unit', widthPx: 400);

    expect(later.loadCalls, 1);
  });

  test('dispose releases the SDK object', () async {
    final loader = _FakeLoader();
    final c = _controller(loader);
    await c.request(adUnitId: 'unit', widthPx: 400);
    c.dispose();
    expect(loader.disposeCalls, 1);
  });

  test('a controller disposed mid-flight publishes nothing', () async {
    final loader = _FakeLoader();
    final c = _controller(loader);
    final pending = c.request(adUnitId: 'unit', widthPx: 400);
    c.dispose();
    await pending;

    // A late callback must not hand an ad to a widget that is already gone.
    expect(c.status, isNot(BannerAdStatus.loaded));
    expect(c.ad, isNull);
  });

  group('telemetry', () {
    test('records request, load and impression — and nothing else', () async {
      final events = <String>[];
      final c = _controller(
        _FakeLoader(fireImpression: true),
        onEvent: (e, p) => events.add('$e:$p'),
      );
      await c.request(adUnitId: 'unit', widthPx: 400);

      // Order beyond "requested first" is the SDK's to decide — the fake
      // fires the impression synchronously, a device fires it after display —
      // so this pins the set and the placement key, not the sequence.
      expect(events.first, 'banner_ad_requested:transactions_list');
      expect(events.toSet(), {
        'banner_ad_requested:transactions_list',
        'banner_ad_impression:transactions_list',
        'banner_ad_loaded:transactions_list',
      });
    });

    test('records a failure', () async {
      final events = <String>[];
      await _controller(
        _FakeLoader(succeeds: false),
        onEvent: (e, p) => events.add(e),
      ).request(adUnitId: 'unit', widthPx: 400);

      expect(events, ['banner_ad_requested', 'banner_ad_failed']);
    });

    test('a suppressed placement emits NOTHING', () async {
      // The design promises an ad-free or non-consenting user produces no
      // telemetry that implies an impression opportunity. A width refusal and a
      // throttle refusal are the two suppression paths reachable here, and
      // neither may say anything.
      final events = <String>[];
      await _controller(_FakeLoader(), onEvent: (e, p) => events.add(e))
          .request(adUnitId: 'unit', widthPx: 100);
      expect(events, isEmpty);

      BannerAdController.resetThrottleForTest();
      final now = DateTime(2026, 9, 1, 12);
      await _controller(_FakeLoader(), clock: () => now)
          .request(adUnitId: 'unit', widthPx: 400);
      final throttled = <String>[];
      await _controller(_FakeLoader(),
              onEvent: (e, p) => throttled.add(e), clock: () => now)
          .request(adUnitId: 'unit', widthPx: 400);
      expect(throttled, isEmpty);
    });

    test('a throwing telemetry sink cannot break the ad', () async {
      final c = _controller(
        _FakeLoader(),
        onEvent: (_, __) => throw StateError('metrics exploded'),
      );
      await c.request(adUnitId: 'unit', widthPx: 400);
      expect(c.status, BannerAdStatus.loaded);
    });
  });
}
