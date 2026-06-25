import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';

/// Premium, glossy "3D-style" onboarding illustration rendered entirely in
/// Flutter — no image assets.
///
/// A rounded squircle badge with a violet gradient, a glossy top sheen, an
/// ambient outer glow, a soft inner border highlight, and a few floating accent
/// particles, with [icon] floating at the center. API is unchanged so existing
/// onboarding screens upgrade automatically.
class NeonIllustration extends StatelessWidget {
  const NeonIllustration({
    super.key,
    required this.icon,
    this.color,
    this.size = 120,
  });

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final base = color ?? c.cta;
    final light = Color.lerp(base, Colors.white, 0.34)!;
    final deep = Color.lerp(base, const Color(0xFF120A2E), 0.48)!;
    final badge = size * 0.62;
    final radius = badge * 0.30;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // ── Ambient outer glow ─────────────────────────────────────────────
          Container(
            width: badge * 1.35,
            height: badge * 1.35,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  base.withValues(alpha: 0.45),
                  base.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),

          // ── Floating accent particles ──────────────────────────────────────
          _particle(top: size * 0.08, left: size * 0.18, d: size * 0.05, color: c.accent),
          _particle(top: size * 0.22, right: size * 0.12, d: size * 0.035, color: light),
          _particle(bottom: size * 0.14, left: size * 0.12, d: size * 0.045, color: base),
          _particle(bottom: size * 0.24, right: size * 0.16, d: size * 0.028, color: c.accent),

          // ── Glossy badge ───────────────────────────────────────────────────
          Container(
            width: badge,
            height: badge,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [light, base, deep],
                stops: const [0.0, 0.55, 1.0],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: deep.withValues(alpha: 0.55),
                  blurRadius: badge * 0.35,
                  offset: Offset(0, badge * 0.12),
                ),
                BoxShadow(
                  color: base.withValues(alpha: 0.45),
                  blurRadius: badge * 0.55,
                  spreadRadius: badge * 0.02,
                ),
              ],
            ),
            child: Stack(
              children: [
                // Glossy top sheen
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: badge * 0.5,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(radius)),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.32),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
                // Centered icon
                Center(
                  child: Icon(
                    icon,
                    size: badge * 0.46,
                    color: Colors.white,
                    shadows: [
                      Shadow(
                        color: deep.withValues(alpha: 0.6),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                ),
              ],
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
          color: color.withValues(alpha: 0.9),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.6),
              blurRadius: d * 1.4,
              spreadRadius: d * 0.1,
            ),
          ],
        ),
      ),
    );
  }
}
