import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_assets.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/premium_glass_container.dart';
import '../../core/utils/l10n_ext.dart';
import 'widgets/coin_rain.dart';
import 'widgets/word_reveal_text.dart';
import '../../core/theme/app_colors.dart';

/// Same flat navy the native launch screen uses (`flutter_native_splash.yaml`,
/// `color: "#021B79"`), so the app never "jumps" from the launch screen to a
/// visually different first frame.
const _onboardingBlue = AppBrandBlue.brand;
const _accentBlue = AppBrandBlue.pale;

/// First-launch cinematic story shown before the brand and mandatory auth.
///
/// Two pages in a [PageView], both on the same flat navy background as the
/// native launch screen with a small fixed logo up top — no photographic
/// artwork. Page 1 ([_PromisePage]) types out a scrollable run of promise
/// copy; page 2 ([_StoryPage]) does the same with a shorter run. Every word
/// on screen — titles, supporting copy, Skip, and the CTAs — is live,
/// localized Flutter text (`context.l10n`), so it stays accessible,
/// RTL-correct, and translatable.
class OnboardingStoryScreen extends StatefulWidget {
  const OnboardingStoryScreen({super.key});

  @override
  State<OnboardingStoryScreen> createState() => _OnboardingStoryScreenState();
}

class _OnboardingStoryScreenState extends State<OnboardingStoryScreen> {
  static const _pageCount = 2;

  final PageController _pageController = PageController();
  int _page = 0;
  bool _navigating = false;

  bool get _reduceMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  void _onPageChanged(int page) => setState(() => _page = page);

  Future<void> _continueFromPage(int page) async {
    if (page < _pageCount - 1) {
      // PageController.animateToPage asserts duration > Duration.zero, so a
      // reduced-motion jump must go through jumpToPage instead.
      if (_reduceMotion) {
        _pageController.jumpToPage(page + 1);
      } else {
        await _pageController.animateToPage(
          page + 1,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
        );
      }
      return;
    }
    _goToBrand();
  }

  void _skip() => _goToBrand();

  void _goToBrand() {
    if (_navigating) return;
    _navigating = true;
    HapticFeedback.selectionClick();
    context.go('/onboarding/brand');
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    precacheImage(const AssetImage(AppAssets.qirshLogoFull), context);
    precacheImage(const AssetImage(AppAssets.handCoinCutout), context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final secondPageData = _StoryPageData(
      title: l10n.storySpendingTitle,
      body: l10n.storySpendingBody,
      highlight: l10n.storySpendingHighlight,
      supporting: l10n.storySpendingSupporting,
      ctaLabel: l10n.storyStartCta,
      semanticLabel: l10n.storyPageTwoSemanticLabel,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              onPageChanged: _onPageChanged,
              itemCount: _pageCount,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Semantics(
                    label: l10n.storyPageOneSemanticLabel,
                    child: _PromisePage(
                      reduceMotion: _reduceMotion,
                      onCta: () => _continueFromPage(0),
                    ),
                  );
                }
                return Semantics(
                  label: secondPageData.semanticLabel,
                  child: _StoryPage(
                    data: secondPageData,
                    reduceMotion: _reduceMotion,
                    onCta: () => _continueFromPage(index),
                  ),
                );
              },
            ),
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  12,
                  AppSpacing.gutter,
                  0,
                ),
                child: AnimatedBuilder(
                  animation: _pageController,
                  builder: (context, _) {
                    final page = _pageController.hasClients
                        ? (_pageController.page ?? _page.toDouble())
                        : _page.toDouble();
                    return _StoryHeader(
                      pageCount: _pageCount,
                      segmentFill: (index) =>
                          (page - index + 1).clamp(0.0, 1.0),
                      skipLabel: l10n.storySkip,
                      onSkip: _skip,
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StoryPageData {
  const _StoryPageData({
    required this.title,
    required this.body,
    required this.highlight,
    required this.supporting,
    required this.ctaLabel,
    required this.semanticLabel,
  });

  final String title;
  final String body;
  final String highlight;
  final String supporting;
  final String ctaLabel;
  final String semanticLabel;
}

class _StoryHeader extends StatelessWidget {
  const _StoryHeader({
    required this.pageCount,
    required this.segmentFill,
    required this.skipLabel,
    required this.onSkip,
  });

  final int pageCount;
  final double Function(int index) segmentFill;
  final String skipLabel;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              for (var i = 0; i < pageCount; i++) ...[
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      height: 3,
                      child: Stack(
                        children: [
                          ColoredBox(
                            color: Colors.white.withValues(alpha: 0.22),
                          ),
                          FractionallySizedBox(
                            widthFactor: segmentFill(i),
                            child: const ColoredBox(color: _accentBlue),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (i < pageCount - 1) const SizedBox(width: 6),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        PremiumGlassContainer(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          blurSigma: 12,
          backgroundColor: Colors.white.withValues(alpha: 0.08),
          borderColor: Colors.white.withValues(alpha: 0.14),
          padding: EdgeInsets.zero,
          child: TextButton(
            onPressed: onSkip,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: Text(skipLabel, style: AppTypography.caption(Colors.white)),
          ),
        ),
      ],
    );
  }
}

class _PromiseBlock {
  const _PromiseBlock(this.text, this.style);

  final String text;
  final TextStyle style;
}

/// First story page: full-bleed decorative artwork (coin top-left, hand/jar
/// bottom-left, clean black field on the right) with a right-aligned,
/// scrollable stack of live copy over it. Kept separate from [_StoryPage]
/// (page 2, unchanged) since the two layouts differ deliberately — page 2
/// is a half-screen image above a fixed text block, this page is a
/// full-screen background behind a taller run of copy.
///
/// The copy types on block by block — like page 2's [WordRevealText] — and
/// the CTA only fades in once the last block finishes.
class _PromisePage extends StatefulWidget {
  const _PromisePage({required this.reduceMotion, required this.onCta});

  final bool reduceMotion;
  final VoidCallback onCta;

  @override
  State<_PromisePage> createState() => _PromisePageState();
}

class _PromisePageState extends State<_PromisePage> {
  final _scrollController = ScrollController();
  int _revealedBlocks = 1;
  bool _textComplete = false;

  void _advance(int blockCount) {
    if (!mounted) return;
    setState(() {
      if (_revealedBlocks < blockCount) {
        _revealedBlocks++;
      } else {
        _textComplete = true;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final width = MediaQuery.sizeOf(context).width;
    final isCompact = width < 360;
    final fontScale = isCompact ? 0.88 : 1.0;
    final columnWidth = width * (isCompact ? 0.62 : 0.7);

    TextStyle style(
            double size, FontWeight weight, double height, Color color) =>
        AppTypography.custom(
          size: size * fontScale,
          weight: weight,
          height: height,
          color: color,
        );

    final blocks = <_PromiseBlock>[
      _PromiseBlock(
        l10n.storyPromiseTitle,
        style(44, FontWeight.w800, 1.14, Colors.white),
      ),
      _PromiseBlock(
        l10n.storyPromiseSubtitle,
        style(22, FontWeight.w500, 1.4, Colors.white.withValues(alpha: 0.9)),
      ),
      _PromiseBlock(
        l10n.storyPromiseHighlight,
        style(21, FontWeight.w600, 1.4, _accentBlue),
      ),
      _PromiseBlock(
        l10n.storyPromiseBody,
        style(19, FontWeight.w400, 1.55, Colors.white.withValues(alpha: 0.86)),
      ),
      _PromiseBlock(
        l10n.storyPromiseSectionTitle,
        style(36, FontWeight.w700, 1.16, Colors.white),
      ),
      _PromiseBlock(
        l10n.storyPromiseSectionBody,
        style(19, FontWeight.w400, 1.55, Colors.white.withValues(alpha: 0.86)),
      ),
      _PromiseBlock(
        l10n.storyPromiseClosing,
        style(21, FontWeight.w600, 1.35, Colors.white),
      ),
    ];
    final gaps = [
      AppSpacing.s3,
      AppSpacing.s5,
      AppSpacing.s4,
      AppSpacing.s6,
      AppSpacing.s3,
      AppSpacing.s6,
    ];
    final visibleCount = _revealedBlocks.clamp(0, blocks.length);

    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: _onboardingBlue),
        const Positioned.fill(child: CoinRain()),
        Positioned(
          left: -width * 0.10,
          bottom: 90,
          child: ExcludeSemantics(
            child: Image(
              image: const AssetImage(AppAssets.handCoinCutout),
              width: width * 0.52,
              fit: BoxFit.fitWidth,
            ),
          ),
        ),
        SafeArea(
          minimum: const EdgeInsets.only(top: AppSpacing.s10 + AppSpacing.s2),
          child: Column(
            children: [
              const ExcludeSemantics(
                child: Image(
                  image: AssetImage(AppAssets.qirshLogoFull),
                  height: 40,
                ),
              ),
              const SizedBox(height: AppSpacing.s5),
              Expanded(
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.gutter,
                  ),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: columnWidth),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < visibleCount; i++) ...[
                            if (i > 0)
                              SizedBox(height: gaps[i - 1] * fontScale),
                            WordRevealText(
                              blocks[i].text,
                              style: blocks[i].style,
                              textAlign: TextAlign.right,
                              hapticPerWord: true,
                              onComplete: () => _advance(blocks.length),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.s3,
                  AppSpacing.gutter,
                  AppSpacing.s6,
                ),
                child: _textComplete
                    ? SizedBox(
                        width: double.infinity,
                        height: AppSpacing.buttonHeight,
                        child: FilledButton(
                          onPressed: widget.onCta,
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: _onboardingBlue,
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.button),
                            ),
                          ),
                          child: Text(
                            l10n.storyContinueCta,
                            style: AppTypography.bodyStrong(
                              _onboardingBlue,
                            ),
                          ),
                        ).animate().fadeIn(
                              duration: widget.reduceMotion
                                  ? Duration.zero
                                  : const Duration(milliseconds: 320),
                            ),
                      )
                    : const SizedBox(height: AppSpacing.buttonHeight),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StoryTextBlock {
  const _StoryTextBlock(this.text, this.style);

  final String text;
  final TextStyle style;
}

/// Second story page: full-bleed decorative artwork (skyline, standing
/// figure, coin, jar, and coin stacks in the upper frame; a dark, clear
/// field below for copy) with title, body, highlight, and supporting lines
/// anchored to that lower field. The text region is capped to a share of
/// the available height so it can never grow up into the artwork's focal
/// objects; it scrolls internally if large accessibility text still
/// overflows that budget.
///
/// The copy types on block by block, matching page 1's reveal pacing, and
/// the CTA only fades in once the last block finishes.
class _StoryPage extends StatefulWidget {
  const _StoryPage({
    required this.data,
    required this.reduceMotion,
    required this.onCta,
  });

  final _StoryPageData data;
  final bool reduceMotion;
  final VoidCallback onCta;

  @override
  State<_StoryPage> createState() => _StoryPageState();
}

class _StoryPageState extends State<_StoryPage> {
  final _scrollController = ScrollController();
  int _revealedBlocks = 1;
  bool _textComplete = false;

  void _advance(int blockCount) {
    if (!mounted) return;
    setState(() {
      if (_revealedBlocks < blockCount) {
        _revealedBlocks++;
      } else {
        _textComplete = true;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final width = MediaQuery.sizeOf(context).width;
    final fontScale = width < 360 ? 0.88 : 1.0;

    TextStyle style(
            double size, FontWeight weight, double height, Color color) =>
        AppTypography.custom(
          size: size * fontScale,
          weight: weight,
          height: height,
          color: color,
        );

    final blocks = <_StoryTextBlock>[
      _StoryTextBlock(
        data.title,
        style(30, FontWeight.w800, 1.16, Colors.white),
      ),
      _StoryTextBlock(
        data.body,
        style(16, FontWeight.w400, 1.5, Colors.white.withValues(alpha: 0.88)),
      ),
      _StoryTextBlock(
        data.highlight,
        style(19, FontWeight.w700, 1.32, _accentBlue),
      ),
      _StoryTextBlock(
        data.supporting,
        style(15, FontWeight.w400, 1.5, Colors.white.withValues(alpha: 0.8)),
      ),
    ];
    final gaps = [AppSpacing.s3, AppSpacing.s4, AppSpacing.s4];
    final visibleCount = _revealedBlocks.clamp(0, blocks.length);

    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: _onboardingBlue),
        const Positioned.fill(child: CoinRain()),
        SafeArea(
          minimum: const EdgeInsets.only(top: AppSpacing.s10 + AppSpacing.s2),
          child: Column(
            children: [
              const ExcludeSemantics(
                child: Image(
                  image: AssetImage(AppAssets.qirshLogoFull),
                  height: 40,
                ),
              ),
              const SizedBox(height: AppSpacing.s5),
              Expanded(
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < visibleCount; i++) ...[
                        if (i > 0) SizedBox(height: gaps[i - 1] * fontScale),
                        WordRevealText(
                          blocks[i].text,
                          style: blocks[i].style,
                          textAlign: TextAlign.right,
                          hapticPerWord: true,
                          onComplete: () => _advance(blocks.length),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.s4,
                  AppSpacing.gutter,
                  AppSpacing.s6,
                ),
                child: _textComplete
                    ? SizedBox(
                        width: double.infinity,
                        height: AppSpacing.buttonHeight,
                        child: FilledButton(
                          onPressed: widget.onCta,
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: _onboardingBlue,
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.button),
                            ),
                          ),
                          child: Text(
                            data.ctaLabel,
                            style: AppTypography.bodyStrong(
                              _onboardingBlue,
                            ),
                          ),
                        ).animate().fadeIn(
                              duration: widget.reduceMotion
                                  ? Duration.zero
                                  : const Duration(milliseconds: 320),
                            ),
                      )
                    : const SizedBox(height: AppSpacing.buttonHeight),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
