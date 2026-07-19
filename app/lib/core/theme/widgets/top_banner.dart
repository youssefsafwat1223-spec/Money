import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_shadows.dart';
import '../app_spacing.dart';
import '../app_typography.dart';

/// Shows a message anchored to the TOP of the screen (below the status bar),
/// instead of the default bottom [SnackBar] — the app-wide replacement for
/// `ScaffoldMessenger.of(context).showSnackBar(...)`.
///
/// Auto-dismisses after [duration], or immediately on tap. Only one banner
/// is shown at a time; a new call replaces whatever is currently visible.
class TopBanner {
  TopBanner._();

  static OverlayEntry? _current;

  static void showError(BuildContext context, String message) =>
      _show(context, message: message, kind: _TopBannerKind.error);

  static void showSuccess(BuildContext context, String message) =>
      _show(context, message: message, kind: _TopBannerKind.success);

  static void showInfo(BuildContext context, String message) =>
      _show(context, message: message, kind: _TopBannerKind.info);

  static void _show(
    BuildContext context, {
    required String message,
    required _TopBannerKind kind,
    Duration duration = const Duration(seconds: 3),
  }) {
    _current?.remove();
    _current = null;

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    late OverlayEntry entry;
    void dismiss() {
      if (_current == entry) {
        entry.remove();
        _current = null;
      }
    }

    entry = OverlayEntry(
      builder: (context) => _TopBannerWidget(
        message: message,
        kind: kind,
        onDismiss: dismiss,
      ),
    );
    _current = entry;
    overlay.insert(entry);
    Future.delayed(duration, dismiss);
  }
}

enum _TopBannerKind { error, success, info }

class _TopBannerWidget extends StatefulWidget {
  const _TopBannerWidget({
    required this.message,
    required this.kind,
    required this.onDismiss,
  });

  final String message;
  final _TopBannerKind kind;
  final VoidCallback onDismiss;

  @override
  State<_TopBannerWidget> createState() => _TopBannerWidgetState();
}

class _TopBannerWidgetState extends State<_TopBannerWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _controller = AnimationController(
      vsync: this,
      duration:
          reduceMotion ? Duration.zero : const Duration(milliseconds: 260),
    );
    _slide = Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
        .animate(
            CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _controller.reverse().whenComplete(widget.onDismiss);
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon) = switch (widget.kind) {
      _TopBannerKind.error => (
          AppColors.light.danger,
          Colors.white,
          Icons.error_outline_rounded
        ),
      _TopBannerKind.success => (
          AppColors.light.success,
          Colors.white,
          Icons.check_circle_outline_rounded
        ),
      _TopBannerKind.info => (
          AppColors.light.cta,
          Colors.white,
          Icons.info_outline_rounded
        ),
    };

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter, AppSpacing.s3, AppSpacing.gutter, 0),
          child: SlideTransition(
            position: _slide,
            child: FadeTransition(
              opacity: _fade,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  onTap: _dismiss,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s4, vertical: AppSpacing.s3),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      boxShadow: AppShadows.elevatedCard,
                    ),
                    child: Row(
                      children: [
                        Icon(icon, color: fg, size: 20),
                        const SizedBox(width: AppSpacing.s3),
                        Expanded(
                          child: Text(
                            widget.message,
                            style: AppTypography.bodyStrong(fg),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
