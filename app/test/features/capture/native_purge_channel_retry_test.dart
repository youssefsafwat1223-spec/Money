import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

/// "THE CHANNEL IS NOT UP YET" IS NOT "THE PURGE FAILED".
///
/// The capture channel is registered from `AppDelegate`, guarded on
/// `rootFlutterViewController()`. Under the UIScene lifecycle that is nil during
/// `didFinishLaunchingWithOptions` — scenes have not connected, so neither
/// `window.rootViewController` nor `connectedScenes` can supply one — and
/// registration is deferred to `applicationDidBecomeActive`. Dart bootstrap runs
/// inside that window.
///
/// The ownership transition treats a failed purge as a reason to withhold
/// admission. Reporting a startup race as a permanent failure is what left the
/// owner marker stranded and wiped every TestFlight user on every launch. So the
/// two conditions have to stay distinguishable:
///
///   MissingPluginException -> not ready yet -> retry, bounded
///   PlatformException      -> the handler ran and refused -> report it
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<Duration> waits;

  setUp(() {
    NativeCaptureBridge.debugTreatHostAsNative = true;
    waits = <Duration>[];
    NativeCaptureBridge.debugDelayOverride = (d) async => waits.add(d);
  });

  tearDown(() {
    NativeCaptureBridge.debugTreatHostAsNative = false;
    NativeCaptureBridge.debugDelayOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('a channel that comes up late is bridged by the retry', () async {
    // Exactly the SceneDelegate window: absent, then registered.
    var attempts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      attempts++;
      if (attempts < 3) throw MissingPluginException('not registered yet');
      return true;
    });

    final ok = await NativeCaptureBridge.purgeAllCaptureState();

    expect(ok, isTrue, reason: 'the purge succeeded once the channel appeared');
    expect(attempts, 3);
    expect(waits.length, 2, reason: 'it waited between attempts, twice');
    expect(waits.every((d) => d == NativeCaptureBridge.purgeChannelRetryDelay),
        isTrue);
  });

  test('the retry is BOUNDED — a permanently absent handler still returns',
      () async {
    var attempts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      attempts++;
      throw MissingPluginException('never registered');
    });

    final ok = await NativeCaptureBridge.purgeAllCaptureState();

    expect(ok, isFalse, reason: 'it gives up and reports failure, honestly');
    expect(attempts, NativeCaptureBridge.purgeChannelRetries,
        reason: 'bounded: a build with the channel removed must not hang '
            'bootstrap forever');
    expect(waits.length, NativeCaptureBridge.purgeChannelRetries - 1);
  });

  test('a REAL native error is not mistaken for a startup race', () async {
    // The handler ran and refused. Retrying would repeat it, and treating it as
    // "not ready" would hide a genuine native failure behind a delay.
    var attempts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      attempts++;
      throw PlatformException(code: 'purge_failed', message: 'keychain denied');
    });

    final ok = await NativeCaptureBridge.purgeAllCaptureState();

    expect(ok, isFalse);
    expect(attempts, 1, reason: 'NOT retried — this is an answer, not silence');
    expect(waits, isEmpty);
  });

  test('a handler that answers first time does not wait at all', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => true);

    expect(await NativeCaptureBridge.purgeAllCaptureState(), isTrue);
    expect(waits, isEmpty, reason: 'no delay on the happy path');
  });

  test('a native false is passed through unchanged', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => false);

    expect(await NativeCaptureBridge.purgeAllCaptureState(), isFalse);
    expect(waits, isEmpty);
  });

  test('the retry budget stays short enough not to stall bootstrap', () {
    final total = NativeCaptureBridge.purgeChannelRetryDelay *
        (NativeCaptureBridge.purgeChannelRetries - 1);
    expect(total.inMilliseconds, lessThanOrEqualTo(1500),
        reason: 'bootstrap has a 30s budget, but this runs before first frame '
            'and must not be felt as launch latency');
  });
}
