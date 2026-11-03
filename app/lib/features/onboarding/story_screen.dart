import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/utils/l10n_ext.dart';
import 'widgets/onboarding_language_button.dart';

/// The approved illustrated introduction. It only explains the product;
/// existing brand/auth/setup routes retain their actual consent decisions.
class OnboardingStoryScreen extends StatefulWidget {
  const OnboardingStoryScreen({super.key});
  @override
  State<OnboardingStoryScreen> createState() => _OnboardingStoryScreenState();
}

class _OnboardingStoryScreenState extends State<OnboardingStoryScreen> {
  final _controller = PageController();
  int _page = 0;
  bool _navigating = false;
  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  void _finish() {
    if (_navigating) return;
    _navigating = true;
    HapticFeedback.selectionClick();
    context.go('/onboarding/brand');
  }

  void _next() {
    if (_page == 3) { _finish(); return; }
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpToPage(_page + 1);
    } else {
      _controller.animateToPage(_page + 1, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l = context.l10n;
    final pages = [
      ('welcome', l.introWelcomeTitle, l.introWelcomeBody),
      ('capture', l.introCaptureTitle, l.introCaptureBody),
      ('budget', l.introBudgetTitle, l.introBudgetBody),
      ('privacy', l.introPrivacyTitle, l.introPrivacyBody),
    ];
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(backgroundColor: c.bg,
        body: SafeArea(child: Column(children: [
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: LayoutBuilder(builder: (context, box) => Row(children: [
              if (_page > 0) IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () {
                  if (MediaQuery.disableAnimationsOf(context)) {
                    _controller.jumpToPage(_page - 1);
                  } else {
                    _controller.previousPage(duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
                  }
                },
                icon: const Icon(Icons.arrow_back_ios_new, size: 18)),
              OnboardingLanguageButton(onDark: false, compact: box.maxWidth < 328),
              const Spacer(),
              TextButton(onPressed: _finish, child: Text(l.storySkip)),
            ]))),
          Expanded(child: PageView.builder(controller: _controller,
            onPageChanged: (page) => setState(() => _page = page), itemCount: pages.length,
            itemBuilder: (context, index) {
              final page = pages[index];
              return LayoutBuilder(builder: (context, box) => SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: ConstrainedBox(constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    QirshIllustration(name: page.$1, width: 260, height: 195),
                    const SizedBox(height: 28),
                    Semantics(label: l.introPageSemantic(index + 1, 4),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        for (var dot = 0; dot < 4; dot++) Container(
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: dot == index ? 22 : 7, height: 7,
                          decoration: BoxDecoration(color: dot == index ? c.cta : c.border,
                            borderRadius: BorderRadius.circular(99))),
                      ])),
                    const SizedBox(height: 24),
                    Text(page.$2, textAlign: TextAlign.center,
                      style: AppTypography.custom(size: 27, weight: FontWeight.w700,
                        height: 1.45, color: c.textPrimary)),
                    const SizedBox(height: 12),
                    if (index == 3) ...[
                      _privacyInfo(context, Icons.lock_outline, l.authTrustLocalEncryption, l.introPrivacyLocalBody),
                      const SizedBox(height: 10),
                      _privacyInfo(context, Icons.public, l.privCloudProcessing, l.introPrivacyCloudBody),
                    ] else Text(page.$3, textAlign: TextAlign.center,
                      style: AppTypography.custom(size: 15, weight: FontWeight.w400,
                        height: 1.75, color: c.textMuted)),
                    const SizedBox(height: 28),
                  ]),
                ),
              ));
            })),
          Padding(padding: const EdgeInsets.fromLTRB(24, 12, 24, 22),
            child: SizedBox(width: double.infinity, height: 52,
              child: FilledButton(onPressed: _next,
                child: Text(_page == 3 ? l.storyStartCta : l.storyContinueCta)))),
        ])),
      ),
    );
  }
  Widget _privacyInfo(BuildContext context, IconData icon, String title, String body) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(16)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 36, height: 36,
          decoration: BoxDecoration(color: c.success.withValues(alpha: .1), borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: c.success, size: 20)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: AppTypography.custom(size: 13, weight: FontWeight.w600, color: c.textPrimary, height: 1.5)),
          const SizedBox(height: 4),
          Text(body, style: AppTypography.custom(size: 11.5, weight: FontWeight.w400, color: c.textMuted, height: 1.6)),
        ])),
      ]),
    );
  }

}
