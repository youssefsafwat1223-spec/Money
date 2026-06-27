import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import 'core/router/app_router.dart';
import 'core/security/app_lock_gate.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_typography.dart';
import 'core/theme/theme_mode_provider.dart';
import 'core/i18n/locale_provider.dart';
import 'features/common/mali_logo.dart';

/// جذر التطبيق. Arabic-first / RTL، يدعم الوضعين.
class MoneyApp extends ConsumerWidget {
  const MoneyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final activeLocale = ref.watch(localeProvider);

    return MaterialApp.router(
      title: 'قرش',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: appRouter,
      scrollBehavior:
          const MaterialScrollBehavior().copyWith(scrollbars: false),

      // تدويل اللغة والاتجاهات ديناميكياً
      locale: activeLocale,
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(
            textScaler: mediaQuery.textScaler.clamp(
              minScaleFactor: 0.8,
              maxScaleFactor: 1.25,
            ),
          ),
          child: _RizonSplashGate(child: AppLockGate(child: child!)),
        );
      },
    );
  }
}

/// شعار البداية المتحرك — Premium Minimalist (Inter + IBM Plex Sans Arabic).
class _MaliSplash extends StatefulWidget {
  const _MaliSplash();

  @override
  State<_MaliSplash> createState() => _MaliSplashState();
}

class _MaliSplashState extends State<_MaliSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  // Animations
  late final Animation<double> _textOpacity;
  late final Animation<Offset> _textSlide;
  late final Animation<double> _textScale;
  late final Animation<double> _letterSpacing;
  late final Animation<double> _loadingOpacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    // Typography: 350ms - 1050ms (0.25 to 0.75 of duration)
    _textOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.25, 0.75, curve: Curves.easeIn),
      ),
    );
    _textSlide = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.25, 0.8, curve: Curves.easeOutExpo),
      ),
    );
    _textScale = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.25, 0.8, curve: Curves.easeOutExpo),
      ),
    );

    // Subtitle Converging animation (tracking-out-contract)
    _letterSpacing = Tween<double>(begin: 20.0, end: 6.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.3, 0.85, curve: Curves.easeOutExpo),
      ),
    );

    // Sleek progress bar appearance: 700ms - 1300ms (0.5 to 0.9 of duration)
    _loadingOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.5, 0.9, curve: Curves.easeIn),
      ),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SizedBox.expand(
      child: _AmbientLiquidBackground(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Spectacular Geometric Logo Assembly
                Stack(
                  alignment: Alignment.center,
                  children: [
                    if (isDark)
                      Container(
                        width: 140,
                        height: 140,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: c.primary.withValues(alpha: 0.12),
                              blurRadius: 44,
                              spreadRadius: 12,
                            ),
                          ],
                        ),
                      ),
                    _AnimatedMaliLogo(
                      animation: _controller,
                      size: 96,
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                // Animated Titles
                AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    return Opacity(
                      opacity: _textOpacity.value,
                      child: Transform.scale(
                        scale: _textScale.value,
                        child: FractionalTranslation(
                          translation: _textSlide.value,
                          child: child,
                        ),
                      ),
                    );
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'قرش',
                        style: AppTypography.display(c.textMain),
                        textAlign: TextAlign.center,
                        textDirection: TextDirection.rtl,
                      ),
                      const SizedBox(height: 8),
                      AnimatedBuilder(
                        animation: _letterSpacing,
                        builder: (context, child) {
                          return Text(
                            'Q I R S H',
                            style: AppTypography.caption(c.textLight).copyWith(
                              letterSpacing: _letterSpacing.value,
                              fontWeight: FontWeight.w700,
                            ),
                            textAlign: TextAlign.center,
                            textDirection: TextDirection.ltr,
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // Sleek breathing loading bar at the bottom
            Positioned(
              bottom: 64,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Opacity(
                    opacity: _loadingOpacity.value,
                    child: child,
                  );
                },
                child: SizedBox(
                  width: 48,
                  child: _SleekLoadingIndicator(
                      color: c.textLight.withValues(alpha: 0.4)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// لوجو «قرش» الرسمي مع دخول ناعم.
class _AnimatedMaliLogo extends StatelessWidget {
  const _AnimatedMaliLogo({
    required this.animation,
    required this.size,
  });

  final Animation<double> animation;
  final double size;

  @override
  Widget build(BuildContext context) {
    final logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: animation,
        curve: const Interval(0.0, 0.42, curve: Curves.easeIn),
      ),
    );
    final logoScale = Tween<double>(begin: 0.86, end: 1.0).animate(
      CurvedAnimation(
        parent: animation,
        curve: const Interval(0.04, 0.8, curve: Curves.easeOutBack),
      ),
    );

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        return Opacity(
          opacity: logoOpacity.value,
          child: Transform.scale(
            scale: logoScale.value,
            child: child,
          ),
        );
      },
      child: MaliLogo(size: size, glow: true),
    );
  }
}

/// خلفية سائلة ومضيئة — Drift Ambient Background
class _AmbientLiquidBackground extends StatefulWidget {
  const _AmbientLiquidBackground({required this.child});
  final Widget child;

  @override
  State<_AmbientLiquidBackground> createState() =>
      _AmbientLiquidBackgroundState();
}

class _AmbientLiquidBackgroundState extends State<_AmbientLiquidBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _driftController;

  @override
  void initState() {
    super.initState();
    _driftController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
  }

  @override
  void dispose() {
    _driftController.dispose();
    super.dispose();
  }

  Size get size => MediaQuery.of(context).size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _driftController,
      builder: (context, child) {
        final t = _driftController.value * 2.0 * pi;

        final dx1 = 0.25 * size.width * cos(t);
        final dy1 = 0.15 * size.height * sin(t);

        final dx2 = 0.2 * size.width * sin(2 * t);
        final dy2 = 0.1 * size.height * cos(2 * t);

        return Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(color: c.bg),
              ),
            ),
            // Light 1: Blue / Teal
            Positioned(
              left: (size.width * 0.15) + dx1,
              top: (size.height * 0.18) + dy1,
              child: Container(
                width: size.width * 0.8,
                height: size.width * 0.8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      (isDark ? c.primary : const Color(0xFFC7E3F0))
                          .withValues(alpha: isDark ? 0.08 : 0.4),
                      (isDark ? c.primary : const Color(0xFFC7E3F0))
                          .withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
            // Light 2: Accent / Success
            Positioned(
              right: (size.width * 0.1) + dx2,
              bottom: (size.height * 0.22) + dy2,
              child: Container(
                width: size.width * 0.9,
                height: size.width * 0.9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      (isDark ? c.accent : const Color(0xFFE3F6EC))
                          .withValues(alpha: isDark ? 0.06 : 0.35),
                      (isDark ? c.accent : const Color(0xFFE3F6EC))
                          .withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(child: widget.child),
          ],
        );
      },
    );
  }
}

class _SleekLoadingIndicator extends StatefulWidget {
  const _SleekLoadingIndicator({required this.color});
  final Color color;

  @override
  State<_SleekLoadingIndicator> createState() => _SleekLoadingIndicatorState();
}

class _SleekLoadingIndicatorState extends State<_SleekLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Opacity(
          opacity: 0.3 + (_pulseController.value * 0.7),
          child: Container(
            height: 2,
            decoration: BoxDecoration(
              color: widget.color,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        );
      },
    );
  }
}

class _RizonSplashGate extends StatefulWidget {
  const _RizonSplashGate({required this.child});

  final Widget child;

  @override
  State<_RizonSplashGate> createState() => _RizonSplashGateState();
}

class _RizonSplashGateState extends State<_RizonSplashGate> {
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    Timer(const Duration(milliseconds: 1400), () {
      if (mounted) {
        setState(() => _visible = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        AnimatedOpacity(
          opacity: _visible ? 1 : 0,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
          child: IgnorePointer(
            ignoring: !_visible,
            // Material ancestor so splash Text doesn't get the debug
            // "missing Material" yellow underline; transparent keeps visuals.
            child: const Material(
              type: MaterialType.transparency,
              child: _MaliSplash(),
            ),
          ),
        ),
      ],
    );
  }
}
