import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/session/app_session.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_typography.dart';

const _gold = Color(0xFFD6AF5D);
const _softGold = Color(0xFFF3D28A);
const _deepNavy = Color(0xFF07111F);
const _ink = Color(0xFF020306);

class QirshWelcomeManifestoScreen extends StatefulWidget {
  const QirshWelcomeManifestoScreen({super.key});

  @override
  State<QirshWelcomeManifestoScreen> createState() =>
      _QirshWelcomeManifestoScreenState();
}

class _QirshWelcomeManifestoScreenState
    extends State<QirshWelcomeManifestoScreen> with TickerProviderStateMixin {
  late final PageController _pageController;
  late final AnimationController _ambientController;
  late final AnimationController _introController;
  late final AnimationController _contentController;

  int _page = 0;
  bool _finishing = false;
  bool _reduceMotion = false;

  static final List<_ManifestoPageSpec> _pages = [
    _ManifestoPageSpec(
      title: 'متحمّسين نبدأ معك.',
      lines: [
        _ManifestoLine.highlighted('أهلًا بك في قِرش،', ['قِرش']),
        _ManifestoLine.plain('رفيقك المالي الذكي لحياة أوضح وأسهل.'),
        _ManifestoLine.gap,
        _ManifestoLine.highlighted(
          'في قِرش، نؤمن أن الاستقرار المالي يبدأ بعادات بسيطة:',
          ['قِرش', 'الاستقرار المالي'],
        ),
        _ManifestoLine.plain('أن تعرف أين يذهب مالك،'),
        _ManifestoLine.plain('أن تلاحظ مصروفاتك الصغيرة،'),
        _ManifestoLine.plain('وأن تتخذ قراراتك بثقة.'),
      ],
    ),
    _ManifestoPageSpec(
      title: 'كل قِرش له قيمة.',
      lines: [
        _ManifestoLine.highlighted(
          'قِرش يساعدك على إدارة أموالك بسهولة:',
          ['قِرش', 'إدارة أموالك'],
        ),
        _ManifestoLine.plain('من تسجيل المصروفات وفهم رسائل البنك،'),
        _ManifestoLine.plain(
          'إلى الميزانيات، الاشتراكات، التنبيهات الذكية، والتقارير الأسبوعية.',
        ),
        _ManifestoLine.gap,
        _ManifestoLine.plain('هدفنا أن توفّر أكثر،'),
        _ManifestoLine.plain('تخطط أذكى،'),
        _ManifestoLine.plain('وتعيش براحة أكبر.'),
        _ManifestoLine.gap,
        _ManifestoLine.highlighted('مع قِرش…', ['قِرش']),
        _ManifestoLine.plain('كل عادة لها أثر،'),
        _ManifestoLine.plain('وكل خطوة تقرّبك من أهدافك.'),
      ],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 16),
    );
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _contentController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _introController.forward();
    _contentController.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.of(context).accessibleNavigation;
    if (_reduceMotion == reduceMotion) return;
    _reduceMotion = reduceMotion;
    if (_reduceMotion) {
      _ambientController.stop();
      _introController.value = 1;
      _contentController.value = 1;
    } else {
      _ambientController.repeat();
      if (!_introController.isCompleted) _introController.forward();
      if (!_contentController.isCompleted) _contentController.forward();
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _ambientController.dispose();
    _introController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await AppSession.instance.markWelcomeManifestoSeen();
    if (!mounted) return;
    context.go(_nextPathAfterWelcome());
  }

  String _nextPathAfterWelcome() {
    final session = AppSession.instance;
    if (session.status == SessionStatus.authenticated) return '/';
    return '/onboarding/auth';
  }

  Future<void> _next() async {
    if (_page == _pages.length - 1) {
      await _finish();
      return;
    }
    await _pageController.animateToPage(
      _page + 1,
      duration:
          _reduceMotion ? Duration.zero : const Duration(milliseconds: 680),
      curve: Curves.easeInOutCubic,
    );
  }

  void _onPageChanged(int value) {
    setState(() => _page = value);
    if (_reduceMotion) {
      _contentController.value = 1;
    } else {
      _contentController.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _pages.length - 1;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: _ink,
        body: Stack(
          children: [
            Positioned.fill(
              child: _ManifestoBackground(animation: _ambientController),
            ),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        onPressed: _finishing ? null : _finish,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white.withValues(alpha: .64),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        child: const Text('تخطي'),
                      ),
                    ),
                  ),
                  Expanded(
                    child: PageView.builder(
                      controller: _pageController,
                      onPageChanged: _onPageChanged,
                      physics: const BouncingScrollPhysics(),
                      itemCount: _pages.length,
                      itemBuilder: (context, index) {
                        return _ManifestoPage(
                          spec: _pages[index],
                          introAnimation: _introController,
                          contentAnimation: _contentController,
                          reduceMotion: _reduceMotion,
                          showLogoReveal: index == 0,
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      24,
                      8,
                      24,
                      18 + MediaQuery.of(context).padding.bottom * .25,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _PageDots(count: _pages.length, activeIndex: _page),
                        const SizedBox(height: 18),
                        _ManifestoButton(
                          label: isLast ? 'ابدأ رحلتك' : 'التالي',
                          loading: _finishing,
                          onTap: _finishing ? null : _next,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ManifestoPage extends StatelessWidget {
  const _ManifestoPage({
    required this.spec,
    required this.introAnimation,
    required this.contentAnimation,
    required this.reduceMotion,
    required this.showLogoReveal,
  });

  final _ManifestoPageSpec spec;
  final Animation<double> introAnimation;
  final Animation<double> contentAnimation;
  final bool reduceMotion;
  final bool showLogoReveal;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compact = size.height < 700;
    final logoSize = compact ? 86.0 : 104.0;
    final topGap = compact ? 10.0 : 24.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.fromLTRB(28, topGap, 28, compact ? 18 : 28),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _LogoReveal(
                  animation: introAnimation,
                  reduceMotion: reduceMotion,
                  size: logoSize,
                  enabled: showLogoReveal,
                ),
                SizedBox(height: compact ? 26 : 38),
                _AnimatedLine(
                  animation: contentAnimation,
                  reduceMotion: reduceMotion,
                  index: 0,
                  child: Text(
                    spec.title,
                    textAlign: TextAlign.right,
                    style: AppTypography.display(Colors.white).copyWith(
                      fontSize: compact ? 30 : 34,
                      height: 1.28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                SizedBox(height: compact ? 18 : 24),
                ...[
                  for (var i = 0; i < spec.lines.length; i++)
                    _AnimatedLine(
                      animation: contentAnimation,
                      reduceMotion: reduceMotion,
                      index: i + 1,
                      child: spec.lines[i].isGap
                          ? SizedBox(height: compact ? 7 : 11)
                          : Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text.rich(
                                TextSpan(children: spec.lines[i].spans),
                                textAlign: TextAlign.right,
                                textDirection: TextDirection.rtl,
                                style: AppTypography.body(
                                  Colors.white.withValues(alpha: .82),
                                ).copyWith(
                                  fontSize: compact ? 15.5 : 16.5,
                                  height: 1.75,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LogoReveal extends StatelessWidget {
  const _LogoReveal({
    required this.animation,
    required this.reduceMotion,
    required this.size,
    required this.enabled,
  });

  final Animation<double> animation;
  final bool reduceMotion;
  final double size;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final raw = enabled && !reduceMotion ? animation.value : 1.0;
        final eased = Curves.easeOutCubic.transform(raw);
        return Opacity(
          opacity: eased,
          child: Transform.translate(
            offset: Offset(0, (1 - eased) * 18),
            child: Transform.scale(
              scale: 0.9 + (.1 * eased),
              child: child,
            ),
          ),
        );
      },
      child: Column(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _gold.withValues(alpha: .30),
                  blurRadius: 48,
                  spreadRadius: 8,
                ),
                BoxShadow(
                  color: _softGold.withValues(alpha: .16),
                  blurRadius: 86,
                  spreadRadius: 14,
                ),
              ],
            ),
            child: Image.asset(
              AppAssets.qirshCoinGold,
              filterQuality: FilterQuality.high,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'قِرش',
            textAlign: TextAlign.center,
            style: AppTypography.title1(_softGold).copyWith(
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _AnimatedLine extends StatelessWidget {
  const _AnimatedLine({
    required this.animation,
    required this.reduceMotion,
    required this.index,
    required this.child,
  });

  final Animation<double> animation;
  final bool reduceMotion;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (reduceMotion) return child;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final start = min(.82, .08 + (index * .075));
        final end = min(1.0, start + .24);
        final progress = ((animation.value - start) / (end - start))
            .clamp(0.0, 1.0)
            .toDouble();
        final eased = Curves.easeOutCubic.transform(progress);
        return Opacity(
          opacity: eased,
          child: Transform.translate(
            offset: Offset(0, (1 - eased) * 14),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class _ManifestoButton extends StatelessWidget {
  const _ManifestoButton({
    required this.label,
    required this.loading,
    required this.onTap,
  });

  final String label;
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: const LinearGradient(
            begin: AlignmentDirectional.centerStart,
            end: AlignmentDirectional.centerEnd,
            colors: [Color(0xFFF3D28A), Color(0xFFD4A84D)],
          ),
          boxShadow: [
            BoxShadow(
              color: _gold.withValues(alpha: .24),
              blurRadius: 30,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: FilledButton(
          onPressed: onTap,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: const Color(0xFF211602),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
          ),
          child: loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF211602),
                  ),
                )
              : Text(
                  label,
                  style: AppTypography.title(const Color(0xFF211602))
                      .copyWith(fontWeight: FontWeight.w800),
                ),
        ),
      ),
    );
  }
}

class _PageDots extends StatelessWidget {
  const _PageDots({required this.count, required this.activeIndex});

  final int count;
  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == activeIndex ? 24 : 7,
            height: 7,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: i == activeIndex
                  ? _gold
                  : Colors.white.withValues(alpha: .22),
            ),
          ),
      ],
    );
  }
}

class _ManifestoBackground extends StatefulWidget {
  const _ManifestoBackground({required this.animation});

  final Animation<double> animation;

  @override
  State<_ManifestoBackground> createState() => _ManifestoBackgroundState();
}

class _ManifestoBackgroundState extends State<_ManifestoBackground> {
  late final List<_Dust> _dust;

  @override
  void initState() {
    super.initState();
    final random = Random(91);
    _dust = List.generate(
      64,
      (_) => _Dust(
        x: random.nextDouble(),
        y: random.nextDouble(),
        radius: .6 + random.nextDouble() * 1.5,
        phase: random.nextDouble() * pi * 2,
        depth: .25 + random.nextDouble() * .75,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, _) {
        return CustomPaint(
          painter: _ManifestoBackgroundPainter(
            dust: _dust,
            time: widget.animation.value,
          ),
          size: Size.infinite,
        );
      },
    );
  }
}

class _Dust {
  const _Dust({
    required this.x,
    required this.y,
    required this.radius,
    required this.phase,
    required this.depth,
  });

  final double x;
  final double y;
  final double radius;
  final double phase;
  final double depth;
}

class _ManifestoBackgroundPainter extends CustomPainter {
  const _ManifestoBackgroundPainter({required this.dust, required this.time});

  final List<_Dust> dust;
  final double time;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final background = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_deepNavy, _ink, Color(0xFF020203)],
        stops: [0, .58, 1],
      ).createShader(rect);
    canvas.drawRect(rect, background);

    final topSheen = Paint()
      ..shader = RadialGradient(
        center: const Alignment(.18, -.88),
        radius: 1.15,
        colors: [
          _gold.withValues(alpha: .13),
          Colors.transparent,
        ],
      ).createShader(rect);
    canvas.drawRect(rect, topSheen);

    final vignette = Paint()
      ..shader = RadialGradient(
        radius: 1.08,
        colors: [
          Colors.transparent,
          Colors.black.withValues(alpha: .50),
        ],
        stops: const [.58, 1],
      ).createShader(rect);
    canvas.drawRect(rect, vignette);

    final paint = Paint();
    for (final particle in dust) {
      final drift = sin((time * pi * 2) + particle.phase) * .012;
      final twinkle = (sin((time * pi * 2) + particle.phase) + 1) / 2;
      paint.color = _softGold.withValues(alpha: .08 + twinkle * .22);
      canvas.drawCircle(
        Offset(
          ((particle.x + drift * particle.depth) % 1) * size.width,
          particle.y * size.height,
        ),
        particle.radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ManifestoBackgroundPainter oldDelegate) {
    return oldDelegate.time != time;
  }
}

class _ManifestoPageSpec {
  const _ManifestoPageSpec({required this.title, required this.lines});

  final String title;
  final List<_ManifestoLine> lines;
}

class _ManifestoLine {
  const _ManifestoLine._(this.text, this.highlights, {this.isGap = false});

  factory _ManifestoLine.plain(String text) => _ManifestoLine._(text, const []);

  factory _ManifestoLine.highlighted(String text, List<String> highlights) {
    return _ManifestoLine._(text, highlights);
  }

  static const gap = _ManifestoLine._('', [], isGap: true);

  final String text;
  final List<String> highlights;
  final bool isGap;

  List<TextSpan> get spans {
    if (isGap || highlights.isEmpty) {
      return [TextSpan(text: text)];
    }
    final spans = <TextSpan>[];
    var cursor = 0;
    while (cursor < text.length) {
      var nextIndex = -1;
      String? nextHighlight;
      for (final highlight in highlights) {
        final index = text.indexOf(highlight, cursor);
        if (index >= 0 && (nextIndex == -1 || index < nextIndex)) {
          nextIndex = index;
          nextHighlight = highlight;
        }
      }
      if (nextIndex == -1 || nextHighlight == null) {
        spans.add(TextSpan(text: text.substring(cursor)));
        break;
      }
      if (nextIndex > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, nextIndex)));
      }
      spans.add(
        TextSpan(
          text: nextHighlight,
          style: const TextStyle(
            color: _softGold,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
      cursor = nextIndex + nextHighlight.length;
    }
    return spans;
  }
}
