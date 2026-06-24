import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import 'motion.dart';

/// خزنة ذكية ثلاثية الأبعاد بتأثير زجاجي متوهج وحلقة تقدم دائرية.
class VaultWidget extends StatefulWidget {
  const VaultWidget({super.key, required this.progress, this.size = 160});

  final double progress;
  final double size;

  @override
  State<VaultWidget> createState() => _VaultWidgetState();
}

class _VaultWidgetState extends State<VaultWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pct = widget.progress.clamp(0.0, 1.0);
    final s = widget.size;

    final childWidget = SizedBox(
      width: s,
      height: s,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // توهج خلفي ناعم بالألوان الأساسية للموقع
          Container(
            width: s * 0.8,
            height: s * 0.8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: c.primary.withValues(alpha: 0.15),
                  blurRadius: 35,
                  spreadRadius: 5,
                ),
              ],
            ),
          ),

          // الجسم الزجاجي الدائري (Glassmorphic Sphere)
          Container(
            width: s * 0.8,
            height: s * 0.8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  c.surface2.withValues(alpha: 0.35),
                  c.surface.withValues(alpha: 0.75),
                ],
                center: Alignment.topLeft,
                radius: 1.0,
              ),
              border: Border.all(
                color: c.primary.withValues(alpha: 0.18),
                width: 1.5,
              ),
            ),
          ),

          // مسار حلقة التقدم الخلفي
          SizedBox(
            width: s * 0.7,
            height: s * 0.7,
            child: CircularProgressIndicator(
              value: 1.0,
              strokeWidth: 5,
              valueColor:
                  AlwaysStoppedAnimation(c.border.withValues(alpha: 0.25)),
            ),
          ),

          // حلقة التقدم الملونة والمضيئة
          SizedBox(
            width: s * 0.7,
            height: s * 0.7,
            child: CircularProgressIndicator(
              value: pct,
              strokeWidth: 7,
              strokeCap: StrokeCap.round,
              valueColor: AlwaysStoppedAnimation(c.accent),
            ),
          ),

          // أيقونة العملات مع النسبة المئوية في المنتصف
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                AppLucideIcons.banknote,
                size: s * 0.18,
                color: pct > 0.0 ? c.accent : c.textMuted,
              ),
              const SizedBox(height: 6),
              Text(
                '${(pct * 100).round()}%',
                style: AppTypography.title1(c.textPrimary).copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: s * 0.16,
                  shadows: [
                    Shadow(
                      color: c.accent.withValues(alpha: 0.35),
                      blurRadius: 12,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (shouldReduceMotion(context)) {
      return childWidget;
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // حركة عائمة ناعمة وثنائية للتفاعل
        final dy = -6 * math.sin(_controller.value * math.pi);
        return Transform.translate(offset: Offset(0, dy), child: child);
      },
      child: childWidget,
    );
  }
}
