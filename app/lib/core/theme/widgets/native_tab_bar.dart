import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// One tab of [NativeTabBar]: an SF Symbol name (its `.fill` variant is used
/// when selected) and the tab's title.
@immutable
class NativeTabBarItem {
  const NativeTabBarItem({required this.symbol, required this.title});

  final String symbol;
  final String title;
}

/// Apple's own `UITabBar` (the `mali_native_tab_bar` platform view), so iOS
/// 26+ renders the real system Liquid Glass tab bar. Only build it when
/// `NativeGlassSupport.isSupported`; the Flutter bar stays the fallback.
class NativeTabBar extends StatefulWidget {
  const NativeTabBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
    required this.dark,
    required this.rtl,
    required this.tint,
  });

  final List<NativeTabBarItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool dark;
  final bool rtl;
  final Color tint;

  /// Placeholder content height above the home indicator until the native
  /// bar reports its own `sizeThatFits` height (which changes across iOS
  /// releases and Dynamic Type), so the slot never hard-codes the metric.
  static const double barHeight = 49;

  @override
  State<NativeTabBar> createState() => _NativeTabBarState();
}

class _NativeTabBarState extends State<NativeTabBar> {
  MethodChannel? _channel;
  double _height = NativeTabBar.barHeight;

  Map<String, Object> get _state => {
        'selected': widget.selectedIndex,
        'dark': widget.dark,
        'rtl': widget.rtl,
        'tint': widget.tint.toARGB32(),
      };

  void _onCreated(int id) {
    _channel = MethodChannel('mali/native_tab_bar_$id')
      ..setMethodCallHandler((call) async {
        if (call.method == 'select' && call.arguments is int) {
          widget.onSelect(call.arguments as int);
        } else if (call.method == 'height' && call.arguments is double) {
          final height = call.arguments as double;
          if (mounted && height != _height) setState(() => _height = height);
        }
      });
  }

  @override
  void didUpdateWidget(NativeTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex ||
        oldWidget.dark != widget.dark ||
        oldWidget.rtl != widget.rtl ||
        oldWidget.tint != widget.tint) {
      _channel?.invokeMethod<void>('update', _state);
    }
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return SizedBox(
      height: _height + safeBottom,
      child: UiKitView(
        // Titles are creation-time only: a language change recreates the bar.
        key: ValueKey(widget.items.map((i) => i.title).join('|')),
        viewType: 'mali_native_tab_bar',
        creationParams: <String, Object>{
          ..._state,
          'items': [
            for (final item in widget.items)
              {'symbol': item.symbol, 'title': item.title},
          ],
        },
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onCreated,
        // Taps belong to UIKit immediately (selection morph, haptics).
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
          Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
        },
      ),
    );
  }
}
