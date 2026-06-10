import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';

/// خزنة 2D بسيطة تمتلئ بالعملات حسب [progress] (0..1).
/// نسخة MVP بحركة خفيفة (تنفّس) — بديل static لـ Rive لاحقاً.
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
    duration: const Duration(seconds: 4),
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

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final dy = -4 * (0.5 - (0.5 - _controller.value).abs()) * 2;
        return Transform.translate(offset: Offset(0, dy), child: child);
      },
      child: SizedBox(
        width: s,
        height: s,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // جسم الخزنة
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                  colors: [c.surface2, c.surface],
                ),
                borderRadius: BorderRadius.circular(s * 0.22),
                border: Border.all(color: c.border, width: 1.5),
              ),
            ),
            // العملات (تعبئة من الأسفل)
            ClipRRect(
              borderRadius: BorderRadius.circular(s * 0.22),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  height: s * pct,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [c.accent.withValues(alpha: 0.95), c.accent],
                    ),
                  ),
                ),
              ),
            ),
            // قرص الخزنة
            Positioned(
              top: s * 0.16,
              right: s * 0.16,
              child: Container(
                width: s * 0.27,
                height: s * 0.27,
                decoration: BoxDecoration(
                  color: c.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: c.accent, width: 3),
                ),
                child: Center(
                  child: Container(
                    width: 4,
                    height: s * 0.1,
                    decoration: BoxDecoration(
                      color: c.accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
            // النسبة
            Text(
              '${(pct * 100).round()}%',
              style: AppTypography.title1(Colors.white).copyWith(
                shadows: const [
                  Shadow(color: Colors.black45, blurRadius: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
