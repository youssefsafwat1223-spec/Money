import 'dart:ui';
import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

LinearGradient maliPrimaryActionGradient(BuildContext context) {
  return context.colors.primaryGradient;
}

Color maliPrimaryActionForeground(BuildContext context) {
  // تدرّج بهاما الأزرق غامق كفاية → نص أبيض دائماً (تباين عالٍ في الوضعين).
  return Colors.white;
}

/// Premium Flat Background.
class PremiumBackground extends StatelessWidget {
  const PremiumBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(child: child),
    );
  }
}

/// Premium Flat Card
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
    
    final baseColor = color ?? c.surface;
    
    final finalBorder = border ?? Border.all(
      color: c.border,
      width: 1,
    );

    Widget content = Container(
      padding: padding ?? const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: baseColor,
        borderRadius: BorderRadius.circular(24),
        border: finalBorder,
      ),
      child: child,
    );

    if (onTap != null) {
      content = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          highlightColor: c.textLight.withValues(alpha: 0.1),
          splashColor: c.textLight.withValues(alpha: 0.1),
          child: content,
        ),
      );
    }

    return content;
  }
}

/// A flat icon wrapper
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
        color: color.withValues(alpha: 0.10),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: color, size: size),
    );
  }
}
