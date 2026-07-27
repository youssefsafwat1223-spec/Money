import 'package:flutter/material.dart';

import '../mali_tokens.dart';

/// CalmCanvas — the shared "combined" screen background: the true-black (or
/// off-white) canvas + a top accent glow + two soft aurora blobs + a faint
/// grain texture. All intensities are mode-aware via [MaliTokens]
/// ([MaliTokens.auroraTop] / [auroraA] / [auroraB] / [grainOpacity]) so the
/// whole background is tuned from one place and inherited by every screen that
/// paints on it (MaliScreen, AppScreenScaffold).
///
/// Pure decoration — [IgnorePointer] on every layer, [child] sits on top.
class CalmCanvas extends StatelessWidget {
  const CalmCanvas({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return Stack(
      children: [
        // Base canvas + the top accent glow (behind the balance hero).
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: t.canvas,
              gradient: RadialGradient(
                center: const Alignment(0, -1.25),
                radius: 1.15,
                colors: [t.auroraTop, Colors.transparent],
                stops: const [0.0, 0.72],
              ),
            ),
          ),
        ),
        // Aurora blob near the top-start corner.
        Positioned(
          top: -110,
          right: -90,
          width: 380,
          height: 360,
          child: _Blob(color: t.auroraA),
        ),
        // Aurora blob near the bottom-end corner.
        Positioned(
          bottom: -130,
          left: -100,
          width: 420,
          height: 400,
          child: _Blob(color: t.auroraB),
        ),
        // Faint grain — 128px tile, mode-aware opacity.
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                image: DecorationImage(
                  image: const AssetImage('assets/textures/grain.png'),
                  repeat: ImageRepeat.repeat,
                  opacity: t.grainOpacity,
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, Colors.transparent],
            stops: const [0.0, 0.68],
          ),
        ),
      ),
    );
  }
}
