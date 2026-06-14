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

/// جذر التطبيق. Arabic-first / RTL، يدعم الوضعين.
class MoneyApp extends ConsumerWidget {
  const MoneyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final activeLocale = ref.watch(localeProvider);

    return MaterialApp.router(
      title: 'مالي',
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

class _MaliSplashState extends State<_MaliSplash> with SingleTickerProviderStateMixin {
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
                        'مالي',
                        style: AppTypography.display(c.textMain),
                        textAlign: TextAlign.center,
                        textDirection: TextDirection.rtl,
                      ),
                      const SizedBox(height: 8),
                      AnimatedBuilder(
                        animation: _letterSpacing,
                        builder: (context, child) {
                          return Text(
                            'M A L I',
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
                  child: _SleekLoadingIndicator(color: c.textLight.withValues(alpha: 0.4)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// لوجو «مالي» الهندسي — مرسوم ومتحرك برمجياً بقطع منفصلة.
class _AnimatedMaliLogo extends StatelessWidget {
  const _AnimatedMaliLogo({
    required this.animation,
    required this.size,
  });

  final Animation<double> animation;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    // Line 1: green, rotated -48 deg
    final line1Width = Tween<double>(begin: 0.0, end: size * 0.76).animate(
      CurvedAnimation(
        parent: animation,
        curve: const Interval(0.0, 0.45, curve: Curves.easeOutCubic),
      ),
    );

    // Line 3: dark green, rotated 72 deg
    final line3Width = Tween<double>(begin: 0.0, end: size * 0.34).animate(
      CurvedAnimation(
        parent: animation,
        curve: const Interval(0.15, 0.55, curve: Curves.easeOutCubic),
      ),
    );

    // Line 4: dark green, horizontal
    final line4Width = Tween<double>(begin: 0.0, end: size * 0.44).animate(
      CurvedAnimation(
        parent: animation,
        curve: const Interval(0.25, 0.65, curve: Curves.easeOutCubic),
      ),
    );

    // Circle: amber
    final circleScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: animation,
        curve: const Interval(0.35, 0.75, curve: Curves.easeOutBack),
      ),
    );

    // Line 2: green, rotated 45 deg
    final line2Width = Tween<double>(begin: 0.0, end: size * 0.22).animate(
      CurvedAnimation(
        parent: animation,
        curve: const Interval(0.45, 0.85, curve: Curves.easeOutCubic),
      ),
    );

    final logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: animation,
        curve: const Interval(0.0, 0.3, curve: Curves.easeIn),
      ),
    );

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        return Opacity(
          opacity: logoOpacity.value,
          child: SizedBox(
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
                      width: line1Width.value,
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
                      width: line3Width.value,
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
                    width: line4Width.value,
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
                  child: Transform.scale(
                    scale: circleScale.value,
                    child: Container(
                      decoration: BoxDecoration(
                        color: c.accent,
                        shape: BoxShape.circle,
                      ),
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
                      width: line2Width.value,
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
          ),
        );
      },
    );
  }
}

/// خلفية سائلة ومضيئة — Drift Ambient Background
class _AmbientLiquidBackground extends StatefulWidget {
  const _AmbientLiquidBackground({required this.child});
  final Widget child;

  @override
  State<_AmbientLiquidBackground> createState() => _AmbientLiquidBackgroundState();
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
                      (isDark ? c.primary : const Color(0xFFC7E3F0)).withValues(alpha: isDark ? 0.08 : 0.4),
                      (isDark ? c.primary : const Color(0xFFC7E3F0)).withValues(alpha: 0.0),
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
                      (isDark ? c.accent : const Color(0xFFE3F6EC)).withValues(alpha: isDark ? 0.06 : 0.35),
                      (isDark ? c.accent : const Color(0xFFE3F6EC)).withValues(alpha: 0.0),
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
            child: const _MaliSplash(),
          ),
        ),
      ],
    );
  }
}
