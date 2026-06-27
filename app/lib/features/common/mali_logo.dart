import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_assets.dart';

/// لوجو «قرش» الرسمي. اسم الكلاس محفوظ لتفادي كسر أماكن الاستخدام القديمة.
class MaliLogo extends StatelessWidget {
  const MaliLogo({super.key, this.size = 120, this.radius, this.glow = false});

  final double size;
  final double? radius;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = radius ?? size * 0.24;

    final Widget logoContent = Image.asset(
      AppAssets.qirshCoin,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
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
