library native_glass_navbar;

export 'liquid_glass_helper.dart';

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:native_glass_navbar/liquid_glass_helper.dart';

class NativeGlassNavBarItem {
  const NativeGlassNavBarItem({required this.label, required this.symbol});

  final String label;
  final String symbol;
}

class TabBarActionButton {
  const TabBarActionButton({required this.symbol, required this.onTap});

  final String symbol;
  final VoidCallback onTap;
}

class NativeGlassNavBar extends StatefulWidget {
  const NativeGlassNavBar({
    super.key,
    required this.tabs,
    required this.currentIndex,
    required this.onTap,
    this.actionButton,
    this.tintColor,
    this.fallback,
  }) : assert(
          tabs.length <= (actionButton == null ? 5 : 4),
          actionButton == null
              ? 'NativeGlassNavBar supports a maximum of 5 tabs.'
              : 'NativeGlassNavBar with an action button supports a maximum of 4 tabs.',
        );

  final List<NativeGlassNavBarItem> tabs;
  final TabBarActionButton? actionButton;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final Color? tintColor;
  final Widget? fallback;

  @override
  State<NativeGlassNavBar> createState() => _NativeGlassNavBarState();
}

class _NativeGlassNavBarState extends State<NativeGlassNavBar> {
  MethodChannel? _channel;
  late Future<bool> _supportLiquidGlassFuture;

  @override
  void initState() {
    super.initState();
    _supportLiquidGlassFuture = _checkLiquidGlassSupport();
  }

  @override
  void didUpdateWidget(NativeGlassNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateNativeView();
  }

  Future<bool> _checkLiquidGlassSupport() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;
    return LiquidGlassHelper.isLiquidGlassSupported();
  }

  int _argb(Color color) {
    final alpha = (color.a * 255).round() & 0xff;
    final red = (color.r * 255).round() & 0xff;
    final green = (color.g * 255).round() & 0xff;
    final blue = (color.b * 255).round() & 0xff;
    return alpha << 24 | red << 16 | green << 8 | blue;
  }

  Map<String, dynamic> _createParams() {
    final tint = widget.tintColor ?? Theme.of(context).colorScheme.primary;
    return {
      'labels': widget.tabs.map((tab) => tab.label).toList(),
      'symbols': widget.tabs.map((tab) => tab.symbol).toList(),
      'actionButtonSymbol': widget.actionButton?.symbol,
      'selectedIndex': widget.currentIndex,
      'isDark': Theme.of(context).brightness == Brightness.dark,
      'tintColor': _argb(tint),
    };
  }

  void _updateNativeView() {
    _channel?.invokeMethod<void>('update', _createParams());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _supportLiquidGlassFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return widget.fallback ?? const SizedBox.shrink();
        }

        if (snapshot.data != true) {
          if (widget.fallback != null) return widget.fallback!;
          if (kDebugMode) {
            developer.log(
              'Liquid glass effect is not supported on this device.',
              name: 'NativeGlassNavBar',
              level: 900,
            );
          }
          return const SizedBox.shrink();
        }

        final bottomPadding = MediaQuery.paddingOf(context).bottom;
        final height = 49.0 + bottomPadding;

        return SizedBox(
          height: height,
          child: UiKitView(
            viewType: 'NativeTabBar',
            creationParams: _createParams(),
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: (id) {
              _channel = MethodChannel('NativeTabBar_$id');
              _channel!.setMethodCallHandler((call) async {
                if (call.method == 'valueChanged') {
                  final args = call.arguments as Map<Object?, Object?>;
                  final index = args['index'] as int;
                  widget.onTap(index);
                }

                if (call.method == 'actionButtonPressed') {
                  widget.actionButton?.onTap();
                }
              });
            },
          ),
        );
      },
    );
  }
}
