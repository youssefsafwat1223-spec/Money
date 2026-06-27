import 'package:flutter/material.dart';

import '../../../core/theme/app_assets.dart';
import '../../../core/theme/app_colors.dart';

/// Qirsh-branded onboarding illustration.
/// Keeps the old API so every onboarding screen gets the new coin identity.
class NeonIllustration extends StatelessWidget {
  const NeonIllustration({
    super.key,
    required this.icon,
    this.color,
    this.size = 120,
    this.showBadge = false,
  });

  final IconData icon;
  final Color? color;
  final double size;
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final base = color ?? c.primary;
    final coin = size * 0.72;
    final badge = size * 0.32;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Container(
            width: coin * 1.22,
            height: coin * 1.22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  c.accent.withValues(alpha: 0.34),
                  base.withValues(alpha: 0.10),
                  base.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
          _particle(
            top: size * 0.09,
            left: size * 0.16,
            d: size * 0.045,
            color: c.accent,
          ),
          _particle(
            top: size * 0.22,
            right: size * 0.11,
            d: size * 0.032,
            color: const Color(0xFF55ABFF),
          ),
          _particle(
            bottom: size * 0.14,
            left: size * 0.13,
            d: size * 0.04,
            color: base,
          ),
          _particle(
            bottom: size * 0.22,
            right: size * 0.16,
            d: size * 0.026,
            color: c.accent,
          ),
          Image.asset(
            AppAssets.qirshCoin,
            width: coin,
            height: coin,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
          if (showBadge)
            PositionedDirectional(
              end: size * 0.13,
              bottom: size * 0.15,
              child: Container(
                width: badge,
                height: badge,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFFFBC926),
                      Color(0xFFC3922D),
                    ],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.54),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: c.accent.withValues(alpha: 0.32),
                      blurRadius: badge * 0.46,
                      offset: Offset(0, badge * 0.14),
                    ),
                  ],
                ),
                child: Icon(
                  icon,
                  size: badge * 0.48,
                  color: const Color(0xFF021B79),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _particle({
    double? top,
    double? left,
    double? right,
    double? bottom,
    required double d,
    required Color color,
  }) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      child: Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.88),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.48),
              blurRadius: d * 1.4,
              spreadRadius: d * 0.1,
            ),
          ],
        ),
      ),
    );
  }
}
