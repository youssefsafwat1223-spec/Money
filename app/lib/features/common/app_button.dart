import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// زر رئيسي بلون CTA (#006FAE / #1A9BD7 dark).
class AppPrimaryButton extends StatelessWidget {
  const AppPrimaryButton({
    super.key,
    required this.label,
    this.onTap,
    this.icon,
    this.loading = false,
    this.disabled = false,
    this.height = 56,
    this.semanticsLabel,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool loading;
  final bool disabled;
  final double height;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _AppButtonBase(
      label: label,
      onTap: onTap,
      icon: icon,
      loading: loading,
      disabled: disabled,
      height: height,
      semanticsLabel: semanticsLabel,
      backgroundColor: c.cta,
      foregroundColor: c.onCta,
      disabledBg: c.disabled,
      disabledFg: c.textMuted,
      side: null,
    );
  }
}

/// زر ثانوي — حد بلون CTA، خلفية شفافة.
class AppSecondaryButton extends StatelessWidget {
  const AppSecondaryButton({
    super.key,
    required this.label,
    this.onTap,
    this.icon,
    this.loading = false,
    this.disabled = false,
    this.height = 56,
    this.semanticsLabel,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool loading;
  final bool disabled;
  final double height;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _AppButtonBase(
      label: label,
      onTap: onTap,
      icon: icon,
      loading: loading,
      disabled: disabled,
      height: height,
      semanticsLabel: semanticsLabel,
      backgroundColor: Colors.transparent,
      foregroundColor: c.cta,
      disabledBg: Colors.transparent,
      disabledFg: c.textMuted,
      side: BorderSide(color: disabled ? c.border : c.cta),
    );
  }
}

/// زر شبحي — نص فقط، بدون حد ولا خلفية.
class AppGhostButton extends StatelessWidget {
  const AppGhostButton({
    super.key,
    required this.label,
    this.onTap,
    this.icon,
    this.loading = false,
    this.disabled = false,
    this.height = 56,
    this.semanticsLabel,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool loading;
  final bool disabled;
  final double height;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _AppButtonBase(
      label: label,
      onTap: onTap,
      icon: icon,
      loading: loading,
      disabled: disabled,
      height: height,
      semanticsLabel: semanticsLabel,
      backgroundColor: Colors.transparent,
      foregroundColor: c.cta,
      disabledBg: Colors.transparent,
      disabledFg: c.textMuted,
      side: null,
    );
  }
}

// ── Private shared implementation ─────────────────────────────────────────────

class _AppButtonBase extends StatelessWidget {
  const _AppButtonBase({
    required this.label,
    required this.onTap,
    required this.icon,
    required this.loading,
    required this.disabled,
    required this.height,
    required this.semanticsLabel,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.disabledBg,
    required this.disabledFg,
    required this.side,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool loading;
  final bool disabled;
  final double height;
  final String? semanticsLabel;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color disabledBg;
  final Color disabledFg;
  final BorderSide? side;

  @override
  Widget build(BuildContext context) {
    final isEnabled = !disabled && !loading && onTap != null;

    return Semantics(
      label: semanticsLabel ?? label,
      button: true,
      enabled: isEnabled,
      child: SizedBox(
        height: height,
        child: ElevatedButton(
          onPressed: isEnabled ? onTap : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
            disabledBackgroundColor: disabledBg,
            disabledForegroundColor: disabledFg,
            elevation: 0,
            shadowColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.button),
              side: side ?? BorderSide.none,
            ),
          ),
          child: loading
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: foregroundColor,
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 18),
                      const SizedBox(width: AppSpacing.s2),
                    ],
                    Text(
                      label,
                      style: AppTypography.bodyStrong(foregroundColor),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
