import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/platform/device_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// THE DEVICE TIMEZONE BRIDGE THAT REPLACED `flutter_timezone`.
///
/// The package was removed because its iOS public header carries an unused
/// `#import <CoreLocation/CoreLocation.h>`, which GeneratedPluginRegistrant.m
/// pulls into Runner — a location-framework reference in an app with no location
/// feature, and the cause of Apple's ITMS-90683. The alternative, declaring
/// `NSLocationWhenInUseUsageDescription`, was rejected: the app never requests
/// location, and `ios_privacy_manifest_test` enforces that all four NSLocation*
/// keys stay absent.
///
/// Two things have to hold. Scheduling must land in the user's own zone, and a
/// cold-start race must not silently pin them to the fallback — the lookup runs
/// at bootstrap's `notifications_init`, which is the same pre-first-frame window
/// where the capture purge once got MissingPluginException and cost users their
/// data (ac622970).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('mali/device_timezone');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<Duration> waits;

  setUpAll(tzdata.initializeTimeZones);

  setUp(() {
    waits = <Duration>[];
    DeviceTimezone.debugDelayOverride = (d) async => waits.add(d);
  });

  tearDown(() {
    DeviceTimezone.debugDelayOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('the bridge', () {
    test('returns the IANA identifier the platform reports', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getLocalTimezone');
        return 'Europe/Berlin';
      });

      expect(await DeviceTimezone.getLocalTimezone(), 'Europe/Berlin');
      expect(waits, isEmpty, reason: 'no delay on the happy path');
    });

    test('asks for nothing but the zone — no permission, no arguments',
        () async {
      // A location-free lookup takes no parameters. If this starts passing
      // arguments, something other than the system setting is being resolved.
      MethodCall? seen;
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return 'Asia/Riyadh';
      });

      await DeviceTimezone.getLocalTimezone();

      expect(seen?.arguments, isNull);
    });

    test('a platform that reports nothing yields null, not a guess', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await DeviceTimezone.getLocalTimezone(), isNull);
      expect(waits, isEmpty, reason: 'null is an ANSWER, not a missing channel');
    });
  });

  group('the cold-start race must not become the permanent timezone', () {
    test('a channel that comes up late is bridged by the retry', () async {
      // Exactly the scene-connect window: absent, then registered.
      var attempts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        attempts++;
        if (attempts < 3) throw MissingPluginException('not registered yet');
        return 'Europe/Berlin';
      });

      expect(await DeviceTimezone.getLocalTimezone(), 'Europe/Berlin',
          reason: 'THE regression — a startup race must not silently pin the '
              'user to the Asia/Riyadh fallback for the whole session');
      expect(attempts, 3);
      expect(waits.length, 2, reason: 'it waited between attempts, twice');
      expect(waits.every((d) => d == DeviceTimezone.channelRetryDelay), isTrue);
    });

    test('the retry is BOUNDED — a permanently absent handler still returns',
        () async {
      var attempts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        attempts++;
        throw MissingPluginException('never registered');
      });

      await expectLater(
        DeviceTimezone.getLocalTimezone(),
        throwsA(isA<MissingPluginException>()),
      );
      expect(attempts, DeviceTimezone.channelRetries,
          reason: 'bounded: bootstrap must not hang on a missing channel');
      expect(waits.length, DeviceTimezone.channelRetries - 1);
    });

    test('a REAL native error is NOT retried', () async {
      // The handler ran and refused. Retrying would repeat it, and treating it
      // as "not ready" would hide a genuine native failure behind a delay.
      var attempts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        attempts++;
        throw PlatformException(code: 'tz_failed', message: 'no zone');
      });

      await expectLater(
        DeviceTimezone.getLocalTimezone(),
        throwsA(isA<PlatformException>()),
      );
      expect(attempts, 1, reason: 'NOT retried — this is an answer, not silence');
      expect(waits, isEmpty);
    });

    test('the retry budget stays short enough not to stall bootstrap', () {
      final total =
          DeviceTimezone.channelRetryDelay * (DeviceTimezone.channelRetries - 1);
      expect(total.inMilliseconds, lessThanOrEqualTo(1000),
          reason: 'this runs before the first frame and must not be felt as '
              'launch latency');
    });
  });

  group('what the notification service does with it', () {
    // Mirrors _configureLocalTimezone: a reported zone becomes tz.local, and
    // anything else falls back to Asia/Riyadh so schedules still fire.
    Future<tz.Location> resolve(Future<String?> Function() lookup) async {
      try {
        final name = await lookup();
        if (name != null) return tz.getLocation(name);
      } catch (_) {
        // fall through
      }
      return tz.getLocation('Asia/Riyadh');
    }

    test('a real zone is used verbatim', () async {
      expect((await resolve(() async => 'America/New_York')).name,
          'America/New_York');
    });

    test('null falls back to Asia/Riyadh, never to UTC', () async {
      // UTC would silently shift every scheduled notification for this app's
      // primary audience; the default has to be the product's own region.
      expect((await resolve(() async => null)).name, 'Asia/Riyadh');
    });

    test('an exhausted retry budget falls back rather than breaking scheduling',
        () async {
      expect(
        (await resolve(
                () async => throw MissingPluginException('no channel'))).name,
        'Asia/Riyadh',
      );
    });

    test('a real native failure falls back too', () async {
      expect(
        (await resolve(() async => throw PlatformException(code: 'x'))).name,
        'Asia/Riyadh',
      );
    });

    test('an unknown zone name falls back instead of throwing', () async {
      // tz.getLocation throws on an unrecognised name. A platform reporting a
      // zone the tz database does not carry must not break initialization.
      expect((await resolve(() async => 'Mars/Olympus_Mons')).name,
          'Asia/Riyadh');
    });
  });
}
