import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../common/mali_logo.dart';
import '../common/vault_widget.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _index = 0;

  static const _lastIndex = 4;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_index >= _lastIndex) {
      context.push('/onboarding/auth');
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: () => context.push('/onboarding/auth'),
                child: Text('تخطّي', style: AppTypography.subhead(c.textLight)),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _index = i),
                children: const [
                  _WelcomePage(),
                  _IntroPage(
                    icon: Icons.sms_outlined,
                    kicker: 'بدون مجهود',
                    title: 'لا تكتب —\nإحنا نفهمها لك',
                    subtitle:
                        'نقرأ رسائل بنكك على جهازك، ونطلّع المبلغ والمتجر ونصنّفها تلقائياً.',
                  ),
                  _VaultPage(),
                  _CountryPage(),
                  _PrivacyPage(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.gutter),
              child: Column(
                children: [
                  _Dots(count: 5, index: _index),
                  const SizedBox(height: AppSpacing.s4),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton(
                      onPressed: _next,
                      style: FilledButton.styleFrom(
                        backgroundColor: c.primary,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.md)),
                      ),
                      child: Text(_index >= _lastIndex ? 'يلا نبدأ' : 'التالي',
                          style: AppTypography.bodyStrong(Colors.white)),
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

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const MaliLogo(size: 148, glow: true),
          const SizedBox(height: AppSpacing.s6),
          ShaderMask(
            shaderCallback: (rect) => LinearGradient(
              colors: [c.gradA, c.gradB],
            ).createShader(rect),
            child: Text('مالي',
                style: AppTypography.display(Colors.white)
                    .copyWith(fontSize: 44, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: AppSpacing.s2),
          Text('صاحبك في فلوسك',
              style: AppTypography.title2(c.textMain)),
          const SizedBox(height: AppSpacing.s3),
          Text('اعرف وين راحت فلوسك، ووفّر وكأنها لعبة يومية.',
              textAlign: TextAlign.center,
              style: AppTypography.body(c.textLight)),
        ],
      ),
    );
  }
}

class _IntroPage extends StatelessWidget {
  const _IntroPage({
    required this.icon,
    required this.kicker,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String kicker;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 132,
            height: 132,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [
                  c.primary.withValues(alpha: 0.18),
                  c.accent.withValues(alpha: 0.16),
                ],
              ),
              borderRadius: BorderRadius.circular(AppRadius.cardLg),
              border: Border.all(color: c.border),
            ),
            child: Icon(icon, size: 60, color: c.primary),
          ),
          const SizedBox(height: AppSpacing.s6),
          Text(kicker, style: AppTypography.subhead(c.primary)),
          const SizedBox(height: AppSpacing.s2),
          Text(title,
              textAlign: TextAlign.center,
              style: AppTypography.title1(c.textMain)),
          const SizedBox(height: AppSpacing.s3),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: AppTypography.body(c.textLight)),
        ],
      ),
    );
  }
}

class _VaultPage extends StatelessWidget {
  const _VaultPage();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const VaultWidget(progress: 0.68, size: 168),
          const SizedBox(height: AppSpacing.s6),
          Text('التحفيز', style: AppTypography.subhead(c.primary)),
          const SizedBox(height: AppSpacing.s2),
          Text('وفّر وكأنها\nلعبة يومية',
              textAlign: TextAlign.center,
              style: AppTypography.title1(c.textMain)),
          const SizedBox(height: AppSpacing.s3),
          Text('حدّد هدفك، وشوف خزنتك تمتلئ مع كل ريال توفّره.',
              textAlign: TextAlign.center,
              style: AppTypography.body(c.textLight)),
        ],
      ),
    );
  }
}

class _CountryPage extends StatelessWidget {
  const _CountryPage();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('وين مكانك؟', style: AppTypography.title2(c.textMain)),
          const SizedBox(height: AppSpacing.s2),
          Text('نضبط العملة والبنوك المدعومة لك.',
              style: AppTypography.body(c.textLight)),
          const SizedBox(height: AppSpacing.s5),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              color: c.primary.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: c.primary, width: 1.5),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text('السعودية',
                      style: AppTypography.bodyStrong(c.textMain)),
                ),
                Icon(Icons.check_circle, color: c.primary),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Text('العملة: ريال سعودي (SAR)',
                style: AppTypography.body(c.textLight)),
          ),
        ],
      ),
    );
  }
}

class _PrivacyPage extends StatelessWidget {
  const _PrivacyPage();

  static const _points = [
    'كل المعالجة على جهازك',
    'نقرأ فقط رسائل البنوك',
    'ما نبيع بياناتك أبداً',
    'تحذف كل شيء وقت ما تبي',
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, size: 56, color: c.primary),
          const SizedBox(height: AppSpacing.s4),
          Text('فلوسك تبقى عندك', style: AppTypography.title2(c.textMain)),
          const SizedBox(height: AppSpacing.s4),
          for (final p in _points)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
              child: Row(
                children: [
                  Icon(Icons.check, size: 20, color: c.primary),
                  const SizedBox(width: AppSpacing.s3),
                  Text(p, style: AppTypography.body(c.textMain)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == index ? 22 : 7,
            height: 7,
            decoration: BoxDecoration(
              color: i == index ? c.primary : c.border,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
      ],
    );
  }
}
