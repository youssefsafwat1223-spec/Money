import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Capability probe for the REAL Apple Liquid Glass material — iOS 26
/// `UIGlassEffect`, exposed by the Runner as the `mali_glass_native`
/// platform view (ported from callstack/liquid-glass).
///
/// The answer is cached process-wide. [isSupported] stays false until
/// [probe] resolves, so callers render their shader/blur fallback for the
/// first frames and upgrade seamlessly.
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
  }

  static bool get isSupported => _supported ?? false;

  static Future<bool> probe() {
    final known = _supported;
    if (known != null) return Future.value(known);
    if (kIsWeb || !Platform.isIOS) {
      _supported = false;
      return Future.value(false);
    }
    return _probe ??=
        _channel.invokeMethod<bool>('isSupported').then<bool>((value) {
      return _supported = value ?? false;
    }).catchError((Object _) {
      // Channel absent (tests, stale host) → no native glass.
      return _supported = false;
    });
  }
}

/// The native glass surface itself, sized by its parent (use inside a
/// [Positioned.fill]). Pure backdrop: it never takes touches — the Flutter
/// content above owns all interaction.
class NativeGlassBackdrop extends StatelessWidget {
  const NativeGlassBackdrop({
    super.key,
    required this.radius,
    required this.dark,
    this.clear = false,
  });

  /// Design corner radius (the native side clamps pill=999 to a circle).
  final double radius;

  /// Locks the material to the app's active theme, which can diverge from
  /// the system theme (in-app theme setting, gallery toggle).
  final bool dark;

  /// Apple's `.clear` style instead of `.regular`.
  final bool clear;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: UiKitView(
        viewType: 'mali_glass_native',
        creationParams: <String, Object>{
          'radius': radius,
          'dark': dark,
          'clear': clear,
        },
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );
  }
}
