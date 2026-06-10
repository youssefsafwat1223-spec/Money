import 'package:flutter/material.dart';

/// لوجو «مالي» — يختار النسخة الفاتحة/الداكنة حسب الثيم.
class MaliLogo extends StatelessWidget {
  const MaliLogo({super.key, this.size = 120, this.radius, this.glow = false});

  final double size;
  final double? radius;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asset =
        isDark ? 'assets/logo/logo_dark.png' : 'assets/logo/logo_light.png';
    final r = radius ?? size * 0.24;

    return Container(
      decoration: glow
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(r),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF8E24AA).withValues(alpha: 0.45),
                  blurRadius: 36,
                  spreadRadius: -6,
                ),
              ],
            )
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: Image.asset(asset, width: size, height: size, fit: BoxFit.cover),
      ),
    );
  }
}
