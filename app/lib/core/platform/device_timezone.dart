import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The device's IANA timezone identifier (e.g. `Asia/Riyadh`).
///
/// This replaces the `flutter_timezone` package. That package's iOS public
/// header carries `#import <CoreLocation/CoreLocation.h>`, which
/// GeneratedPluginRegistrant.m pulls into Runner — putting a location-framework
/// reference into an app that has no location feature, and earning Apple's
/// ITMS-90683 ("missing NSLocationWhenInUseUsageDescription"). The import is
/// unused by the plugin itself (both native implementations read the zone from
/// the platform's own date APIs) and it is still present upstream as of 5.1.0,
/// so dropping the dependency is the only way to drop the reference. Declaring a
/// location purpose string instead was rejected: the app never requests
/// location, and `ios_privacy_manifest_test` enforces that all four NSLocation*
/// keys stay absent.
///
/// The native side is Foundation / `java.util` only — `TimeZone.current
/// .identifier` on iOS, `TimeZone.getDefault().id` on Android. Neither reads
/// location nor needs any permission.
class DeviceTimezone {
  const DeviceTimezone._();

  static const MethodChannel _channel = MethodChannel('mali/device_timezone');

  /// "THE CHANNEL IS NOT UP YET" IS NOT "THIS DEVICE HAS NO TIMEZONE".
  ///
  /// `LocalNotificationService.initialize()` runs at bootstrap's
  /// `notifications_init` step, before the first frame. The native handler is
  /// registered from `scene(_:willConnectTo:)`, which is the earliest
  /// deterministic UIScene point and precedes that call — but a startup race is
  /// exactly the failure this app has already paid for once (ac622970), so the
  /// lookup does not treat a momentarily absent channel as a final answer.
  ///
  /// Without this, an ordinary cold-start race would silently pin the user to
  /// the `Asia/Riyadh` fallback for the whole session even though their real zone
  /// was available milliseconds later — every scheduled notification then fires
  /// at the wrong local time, with nothing to indicate why.
  ///
  /// Bounded, and narrow: only `MissingPluginException` is retried, because only
  /// that means "no handler is registered yet". A `PlatformException` is the
  /// handler having run and refused, and is returned as-is.
  @visibleForTesting
  static const int channelRetries = 5;

  @visibleForTesting
  static const Duration channelRetryDelay = Duration(milliseconds: 100);

  /// Swapped out in tests so the retry budget costs no wall-clock time.
  @visibleForTesting
  static Future<void> Function(Duration)? debugDelayOverride;

  /// The platform's current IANA zone name, or null when the platform reports
  /// none. Callers decide the fallback — this never invents a zone.
  ///
  /// Throws [MissingPluginException] if the channel never appears within the
  /// retry budget, and rethrows a [PlatformException] immediately.
  static Future<String?> getLocalTimezone() async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _channel.invokeMethod<String>('getLocalTimezone');
      } on MissingPluginException {
        if (attempt >= channelRetries - 1) rethrow;
        final delay = debugDelayOverride;
        if (delay != null) {
          await delay(channelRetryDelay);
        } else {
          await Future<void>.delayed(channelRetryDelay);
        }
      }
    }
  }
}
