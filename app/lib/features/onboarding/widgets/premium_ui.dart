import 'dart:ui';
import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

const _maliAmberActionGradient = LinearGradient(
  colors: [Color(0xFFFFB300), Color(0xFFFF9500)],
  begin: Alignment.topRight,
  end: Alignment.bottomLeft,
);

LinearGradient maliPrimaryActionGradient(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? _maliAmberActionGradient : context.colors.primaryGradient;
}

Color maliPrimaryActionForeground(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? context.colors.primary : Colors.white;
}

/// Premium Mesh Gradient Background.
class PremiumBackground extends StatelessWidget {
  const PremiumBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _MaliMeshPainter(colors: c, isDark: isDark),
            ),
          ),
          SafeArea(child: child),
        ],
      ),
    );
  }
}

class _MaliMeshPainter extends CustomPainter {
  const _MaliMeshPainter({required this.colors, required this.isDark});

  final AppColors colors;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()..color = colors.bg;
    canvas.drawRect(Offset.zero & size, base);

    void radial({
      required Offset center,
      required double radius,
      required Color color,
    }) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
          stops: const [0, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }

    radial(
      center: Offset(size.width * 0.88, -size.height * 0.04),
      radius: isDark ? 300 : 260,
      color: colors.accent.withValues(alpha: isDark ? 0.14 : 0.10),
    );
    radial(
      center: Offset(0, size.height * 1.02),
      radius: isDark ? 320 : 280,
      color: (isDark ? const Color(0xFF1A3F66) : colors.primary)
          .withValues(alpha: isDark ? 0.35 : 0.06),
    );
    radial(
      center: Offset(size.width * 0.58, size.height * 0.42),
      radius: 220,
      color: colors.surface.withValues(alpha: isDark ? 0.04 : 0.16),
    );
  }

  @override
  bool shouldRepaint(covariant _MaliMeshPainter oldDelegate) {
    return oldDelegate.colors != colors || oldDelegate.isDark != isDark;
  }
}

/// Premium Glass Card
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key, 
    required this.child, 
    this.padding, 
    this.color,
    this.border,
    this.onTap,
  });
  
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color? color;
  final Border? border;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final baseColor = color ?? (isDark ? Colors.white : c.surface);
    final bgAlpha = isDark ? 0.07 : 0.72;
    
    final finalBorder = border ?? Border.all(
      color: isDark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.white.withValues(alpha: 0.70),
      width: 1,
    );

    Widget content = Container(
      padding: padding ?? const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: baseColor.withValues(alpha: bgAlpha),
        borderRadius: BorderRadius.circular(24),
        border: finalBorder,
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.70)
                : c.primary.withValues(alpha: 0.10),
            blurRadius: isDark ? 40 : 34,
            spreadRadius: isDark ? -18 : -16,
            offset: Offset(0, isDark ? 18 : 14),
          ),
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.40)
                : c.primary.withValues(alpha: 0.04),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: child,
    );

    if (onTap != null) {
      content = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          highlightColor: Colors.white.withValues(alpha: 0.1),
          splashColor: Colors.white.withValues(alpha: 0.1),
          child: content,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: content,
      ),
    );
  }
}

/// A glowing icon wrapper
class GlowingIcon extends StatelessWidget {
  const GlowingIcon({
    super.key,
    required this.icon,
    required this.color,
    this.size = 28,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.3),
            blurRadius: 20,
            spreadRadius: -5,
          ),
        ],
      ),
      child: Icon(icon, color: color, size: size),
    );
  }
}
