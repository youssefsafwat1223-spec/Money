import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_colors.dart';
import '../app_spacing.dart';
import '../app_typography.dart';
import '../../utils/app_lucide_icons.dart';
import 'mali_glass.dart';

/// A premium top-floating toast notification system.
class AppToast {
  static OverlayEntry? _currentToast;
  static Timer? _timer;

  /// Shows a success or neutral notification at the top of the screen.
  static void show(BuildContext context, String message) {
    _showToast(Overlay.of(context, rootOverlay: true), message, isError: false);
  }

  /// Shows an error notification at the top of the screen.
  static void showError(BuildContext context, String message) {
    _showToast(Overlay.of(context, rootOverlay: true), message, isError: true);
  }

  /// Uses a root overlay captured before an asynchronous route/scope change.
  /// A disposed host is ignored without reading the former screen's context.
  static void showErrorInOverlay(OverlayState overlay, String message) {
    _showToast(overlay, message, isError: true);
  }

  static void _showToast(OverlayState overlayState, String message,
      {required bool isError}) {
    if (!overlayState.mounted) return;
    // Dismiss existing toast if any
    _currentToast?.remove();
    _currentToast = null;
    _timer?.cancel();

    if (isError) {
      HapticFeedback.heavyImpact();
    } else {
      HapticFeedback.lightImpact();
    }

    _currentToast = OverlayEntry(
      builder: (context) => _ToastWidget(
        message: message,
        isError: isError,
        onDismiss: () {
          _currentToast?.remove();
          _currentToast = null;
        },
      ),
    );

    overlayState.insert(_currentToast!);

    // Auto-dismiss after 3 seconds
    _timer = Timer(const Duration(seconds: 3), () {
      _currentToast?.remove();
      _currentToast = null;
    });
  }
}

class _ToastWidget extends StatefulWidget {
  const _ToastWidget({
    required this.message,
    required this.isError,
    required this.onDismiss,
  });

  final String message;
  final bool isError;
  final VoidCallback onDismiss;

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _slideAnimation;

  bool _entered = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _slideAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entered) return;
    _entered = true;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) _controller.duration = Duration.zero;
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    await _controller.reverse();
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final topPadding = MediaQuery.of(context).padding.top;

    return Positioned(
      top: topPadding + 16,
      left: AppSpacing.gutter,
      right: AppSpacing.gutter,
      child: Material(
        type: MaterialType.transparency,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Transform.translate(
              offset: Offset(0, -100 * (1 - _slideAnimation.value)),
              child: Opacity(
                opacity: _controller.value.clamp(0.0, 1.0),
                child: child,
              ),
            );
          },
          child: GestureDetector(
            onTap: _dismiss,
            onVerticalDragUpdate: (details) {
              if (details.delta.dy < -5) {
                _dismiss();
              }
            },
            // Liquid Glass pill; an error tints the glass red.
            child: MaliGlass(
              variant: MaliGlassVariant.pill,
              padding: EdgeInsets.zero,
              nativeMaterial: true,
              tint: widget.isError ? Colors.red.withValues(alpha: 0.14) : null,
              // Keep text legible over photographs and the navy header even
              // when the native material samples a dark background in light mode.
              child: Container(
                decoration: BoxDecoration(
                  color: widget.isError ? c.dangerBg : c.surfaceCard,
                  borderRadius: BorderRadius.circular(999),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    Icon(
                      widget.isError
                          ? AppLucideIcons.alertCircle
                          : AppLucideIcons.checkCircle,
                      color: widget.isError ? c.danger : c.success,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.message,
                        style: AppTypography.bodyStrong(c.textMain),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
