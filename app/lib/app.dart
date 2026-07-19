import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import 'core/router/app_router.dart';
import 'core/security/app_lock_gate.dart';
import 'core/session/app_session.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/app_assets.dart';
import 'core/theme/app_colors.dart';
import 'core/i18n/locale_provider.dart';
import 'core/theme/widgets/mesh_gradient_bg.dart';

/// جذر التطبيق. Arabic-first / RTL.
class MoneyApp extends ConsumerWidget {
  const MoneyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeLocale = ref.watch(localeProvider);

    return MaterialApp.router(
      title: 'قرش',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
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
  late final Animation<double> _textScale;
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
    _textScale = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.25, 0.8, curve: Curves.easeOutExpo),
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

    return SizedBox.expand(
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: MeshGradientBackground(
              backgroundColor: const Color(0xFFE8F2F6),
              primaryColor: c.primary.withValues(alpha: 0.4),
              secondaryColor: const Color(0xFFF4C84B).withValues(alpha: 0.3),
              tertiaryColor: c.accent.withValues(alpha: 0.2),
            ),
          ),
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Opacity(
              opacity: _textOpacity.value,
              child: Transform.translate(
                offset: Offset(0, 10 * (1 - _textOpacity.value)),
                child: Transform.scale(scale: _textScale.value, child: child),
              ),
            ),
            child: Image.asset(
              AppAssets.getLogoTagline(context),
              width: 260,
              filterQuality: FilterQuality.high,
            ),
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
  late final bool _enabled;
  late bool _visible;

  @override
  void initState() {
    super.initState();
    _enabled = AppSession.instance.status != SessionStatus.authenticated;
    _visible = _enabled;
    if (!_enabled) return;
    Timer(const Duration(milliseconds: 1400), () {
      if (mounted) {
        setState(() => _visible = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) return widget.child;
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
