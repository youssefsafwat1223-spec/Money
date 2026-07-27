import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../core/theme/app_assets.dart';
import '../../common/motion.dart';

/// Falling gold قِرش coins for the story pages.
///
/// On entry a short **burst** of coins showers down once, then a sparse, slow
/// **drizzle** keeps looping faintly in the background. Reuses the existing
/// gold coin art ([AppAssets.qirshCoinGold]). Purely decorative — it ignores
/// pointer events and renders nothing when reduced motion is on.
class CoinRain extends StatelessWidget {
  const CoinRain({super.key});

  // Burst coins: (leftFraction, size, delayMs, durationMs, tiltRadians).
  // Fall once on entry, staggered, then stay off-screen.
  static const List<(double, double, int, int, double)> _burst = [
    (0.08, 20, 0, 1500, -0.25),
    (0.20, 14, 220, 1700, 0.15),
    (0.31, 24, 90, 1350, 0.30),
    (0.42, 13, 380, 1800, -0.18),
    (0.52, 18, 150, 1550, 0.22),
    (0.62, 22, 300, 1400, -0.30),
    (0.71, 15, 60, 1650, 0.10),
    (0.80, 26, 260, 1300, -0.12),
    (0.90, 16, 430, 1750, 0.28),
    (0.14, 12, 520, 1850, -0.20),
    (0.47, 15, 620, 1600, 0.18),
    (0.75, 13, 700, 1700, -0.24),
  ];

  // Drizzle coins: (leftFraction, size, durationMs, delayMs, opacity, tilt).
  // Loop forever, sparse and slow.
  static const List<(double, double, int, int, double, double)> _drizzle = [
    (0.12, 15, 5200, 400, 0.30, -0.20),
    (0.34, 12, 6400, 1600, 0.24, 0.16),
    (0.55, 17, 5600, 900, 0.28, -0.14),
    (0.73, 13, 6800, 2400, 0.22, 0.20),
    (0.88, 14, 6000, 3100, 0.26, -0.24),
  ];

  Widget _coin(double size, double tilt, double opacity) => Opacity(
        opacity: opacity,
        child: Transform.rotate(
          angle: tilt,
          child: Image.asset(
            AppAssets.qirshCoinGold,
            width: size,
            height: size,
            filterQuality: FilterQuality.medium,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (shouldReduceMotion(context)) return const SizedBox.shrink();

    return IgnorePointer(
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            final h = c.maxHeight;
            final travel = h + 60;

            final coins = <Widget>[
              for (final (leftF, size, delayMs, durMs, tilt) in _burst)
                Positioned(
                  left: leftF * w - size / 2,
                  top: -size - 20,
                  child: _coin(size, tilt, 0.85)
                      .animate(delay: Duration(milliseconds: delayMs))
                      .moveY(
                        begin: 0,
                        end: travel,
                        duration: Duration(milliseconds: durMs),
                        curve: Curves.easeIn,
                      )
                      .fade(begin: 0, end: 1, duration: 200.ms),
                ),
              for (final (leftF, size, durMs, delayMs, opacity, tilt)
                  in _drizzle)
                Positioned(
                  left: leftF * w - size / 2,
                  top: -size - 20,
                  child: _coin(size, tilt, opacity)
                      .animate(
                        onPlay: (controller) => controller.repeat(),
                        delay: Duration(milliseconds: delayMs),
                      )
                      .moveY(
                        begin: 0,
                        end: travel,
                        duration: Duration(milliseconds: durMs),
                        curve: Curves.linear,
                      ),
                ),
            ];

            return Stack(children: coins);
          },
        ),
      ),
    );
  }
}
