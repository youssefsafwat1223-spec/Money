import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Capability probe for the REAL Apple Liquid Glass material — iOS 26
/// `UIGlassEffect`, exposed by the Runner as the `mali_glass_native`
/// platform view — plus the one glass-related accessibility setting Flutter's
/// [MediaQuery] does not carry: iOS Reduce Transparency.
///
/// Native glass is opt-in per surface (`MaliGlass.nativeMaterial`): explicit
/// chrome hosts only (sheets, dialogs, toasts, banners, the fallback nav).
/// Generic `MaliGlass` surfaces never become platform views merely because
/// the OS is iOS 26. Enforced by `mali_glass_test.dart`.
///
/// The answers are cached process-wide. [isSupported] stays false until
/// [probe] resolves.
class NativeGlassSupport {
  NativeGlassSupport._();

  static const _channel = MethodChannel('mali/native_glass');
  static bool? _supported;
  static Future<bool>? _probe;

  /// Test hook: forces a value (null clears back to unknown).
  @visibleForTesting
  static set debugOverride(bool? value) {
    _supported = value;
    _probe = null;
    supported.value = value ?? false;
    reduceTransparency.value = false;
  }

  static bool get isSupported => _supported ?? false;

  /// iOS Settings > Accessibility > Display & Text Size > Reduce
  /// Transparency, kept live from the Runner's change notification. The
  /// Dart-drawn glass tiers render opaque while it is on; native
  /// `UIGlassEffect` adapts by itself.
  static final ValueNotifier<bool> reduceTransparency =
      ValueNotifier<bool>(false);

  /// Rebuild hook: surfaces built before [probe] resolved switch to the
  /// native material once the answer arrives.
  static final ValueNotifier<bool> supported = ValueNotifier<bool>(false);

  static Future<bool> probe() {
    final known = _supported;
    if (known != null) return Future.value(known);
    if (kIsWeb || !Platform.isIOS) {
      _supported = false;
      return Future.value(false);
    }
    return _probe ??=
        _channel.invokeMethod<bool>('isSupported').then<bool>((value) {
      _supported = value ?? false;
      supported.value = _supported!;
      _watchReduceTransparency();
      return _supported!;
    }).catchError((Object _) {
      // Channel absent (tests, stale host) → no native glass.
      return _supported = false;
    });
  }

  static void _watchReduceTransparency() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'reduceTransparencyChanged') {
        reduceTransparency.value = call.arguments == true;
      }
    });
    _channel.invokeMethod<bool>('reduceTransparency').then((value) {
      reduceTransparency.value = value ?? false;
    }, onError: (Object _) {
      // Older Runner without the method: keep the translucent default.
    });
  }
}

/// The native glass surface itself, sized by its parent (use inside a
/// [Positioned.fill]). Pure backdrop: it never takes touches — the Flutter
/// content above owns all interaction.
///
/// Parameters are creation-time on the native side, so the view is keyed on
/// them: a theme switch or tint change rebuilds it in place, with no restart.
class NativeGlassBackdrop extends StatelessWidget {
  const NativeGlassBackdrop({
    super.key,
    required this.radius,
    required this.dark,
    this.clear = false,
    this.tint,
  });

  /// Design corner radius (the native side clamps pill=999 to a circle).
  final double radius;

  /// Locks the material to the app's active theme, which can diverge from
  /// the system theme (in-app theme setting, gallery toggle).
  final bool dark;

  /// Apple's `.clear` style instead of `.regular`.
  final bool clear;

  /// `UIGlassEffect.tintColor` — a semantic tint the system blends into the
  /// material under the user's glass and accessibility settings.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final tint = this.tint;
    return IgnorePointer(
      child: UiKitView(
        key: ValueKey<Object?>((dark, clear, tint?.toARGB32())),
        viewType: 'mali_glass_native',
        creationParams: <String, Object>{
          'radius': radius,
          'dark': dark,
          'clear': clear,
          if (tint != null) 'tint': tint.toARGB32(),
        },
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );
  }
}
