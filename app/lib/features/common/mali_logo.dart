import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// لوجو «مالي» الهندسي — مرسوم برمجياً ليطابق تصميم الويب بدقة.
class MaliLogo extends StatelessWidget {
  const MaliLogo({super.key, this.size = 120, this.radius, this.glow = false});

  final double size;
  final double? radius;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = radius ?? size * 0.24;

    final Widget logoContent = SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Line 1: green, rotated -48 deg
          Positioned(
            left: size * 0.16,
            top: size * 0.44,
            child: Transform.rotate(
              angle: -48 * 3.141592653589793 / 180,
              alignment: Alignment.centerLeft,
              child: Container(
                width: size * 0.76,
                height: size * 0.12,
                decoration: BoxDecoration(
                  color: c.success,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
          ),

          // Line 3: dark green, rotated 72 deg
          Positioned(
            left: size * 0.18,
            top: size * 0.36,
            child: Transform.rotate(
              angle: 72 * 3.141592653589793 / 180,
              alignment: Alignment.centerLeft,
              child: Container(
                width: size * 0.34,
                height: size * 0.11,
                decoration: BoxDecoration(
                  color: const Color(0xFF0A7A4F),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
          ),

          // Line 4: dark green, horizontal
          Positioned(
            left: size * 0.12,
            bottom: size * 0.18,
            child: Container(
              width: size * 0.44,
              height: size * 0.14,
              decoration: BoxDecoration(
                color: const Color(0xFF0A7A4F),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),

          // Circle: amber
          Positioned(
            left: size * 0.09,
            bottom: size * 0.18,
            width: size * 0.16,
            height: size * 0.16,
            child: Container(
              decoration: BoxDecoration(
                color: c.accent,
                shape: BoxShape.circle,
              ),
            ),
          ),

          // Line 2: green, rotated 45 deg
          Positioned(
            right: size * 0.02,
            top: size * 0.01,
            child: Transform.rotate(
              angle: 45 * 3.141592653589793 / 180,
              alignment: Alignment.center,
              child: Container(
                width: size * 0.22,
                height: size * 0.12,
                decoration: BoxDecoration(
                  color: c.success,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (glow) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(r),
          boxShadow: [
            BoxShadow(
              color: c.accent.withValues(alpha: 0.25),
              blurRadius: size * 0.42,
              spreadRadius: -size * 0.06,
            ),
          ],
        ),
        child: logoContent,
      );
    }
    return logoContent;
  }
}
