import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';
import '../common/mali_logo.dart';
import 'onboarding_options.dart';
import 'widgets/premium_ui.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color,
    {bool tabular = false, List<Shadow>? shadows}) {
  return GoogleFonts.alexandria(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
    shadows: shadows,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  );
}

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  int _currentIndex = 0;
  static const int _pageCount = 4;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_currentIndex < _pageCount - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    } else {
      // Last page (Country) — persist selection then go to auth.
      final country = ref.read(onboardingSelectionProvider);
      try {
        await ref
            .read(saveCountryCurrencyUseCaseProvider)
            .call(country.code, country.currencyCode);
      } catch (_) {
        // Non-blocking — settings have a sensible default.
      }
      if (mounted) context.go('/onboarding/auth');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PremiumBackground(
      child: Column(
        children: [
          _TopFrame(index: _currentIndex),
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const BouncingScrollPhysics(),
              onPageChanged: (i) => setState(() => _currentIndex = i),
              children: const [
                _WelcomePage(),
                _HowItWorksPage(),
                _PrivacyPage(),
                _CountryPage(),
              ],
            ),
          ),
          _BottomBar(
            index: _currentIndex,
            count: _pageCount,
            onNext: _next,
          ),
        ],
      ),
    );
  }
}

class _TopFrame extends StatelessWidget {
  const _TopFrame({required this.index});
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.gutter, vertical: AppSpacing.s3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: c.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              '${index + 1} / ${_OnboardingScreenState._pageCount}',
              style: _alex(11, FontWeight.w800, 1.2, c.accent),
            ),
          ),
          if (index < _OnboardingScreenState._pageCount - 1)
            TextButton(
              onPressed: () => context.go('/onboarding/auth'),
              style: TextButton.styleFrom(
                backgroundColor: Colors.transparent,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              ),
              child: Text(
                context.l10n.skip,
                style: _alex(12, FontWeight.w700, 1.2, c.textLight),
              ),
            )
          else
            const SizedBox(width: 48, height: 20),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar(
      {required this.index, required this.count, required this.onNext});

  final int index;
  final int count;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    const actionGradient = LinearGradient(
      colors: [Color(0xFFFFB300), Color(0xFFFF9500)],
      begin: Alignment.topRight,
      end: Alignment.bottomLeft,
    );
    final actionForeground = c.primary;

    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, 16, AppSpacing.gutter, 28),
      child: Align(
        alignment: Alignment.center,
        child: Container(
          height: 54,
          width: 150,
          decoration: BoxDecoration(
            gradient: actionGradient,
            borderRadius: BorderRadius.circular(27),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFFB300).withValues(alpha: 0.35),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ElevatedButton(
            onPressed: onNext,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.transparent,
              shadowColor: Colors.transparent,
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(27)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  context.l10n.next,
                  style: _alex(15, FontWeight.w800, 1.2, actionForeground),
                ),
                const SizedBox(width: 6),
                Icon(
                  Directionality.of(context) == TextDirection.rtl
                      ? Icons.chevron_left_rounded
                      : Icons.chevron_right_rounded,
                  color: actionForeground,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Pages ────────────────────────────────────────────────────────────────────

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      children: [
        const SizedBox(height: 40),
        const Center(child: MaliLogo(size: 90, glow: false)),
        const SizedBox(height: 32),
        Text(
          context.l10n.welcomeTitle,
          textAlign: TextAlign.center,
          style: _alex(28, FontWeight.w800, 1.3, c.textMain),
        ),
        const SizedBox(height: 8),
        Text(
          context.l10n.welcomeSubtitle,
          textAlign: TextAlign.center,
          style: _alex(16, FontWeight.w600, 1.4, c.textLight),
        ),
        const SizedBox(height: 24),
        Center(
          child: Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: c.accent,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Text(
            context.l10n.welcomeDescription,
            textAlign: TextAlign.center,
            style: _alex(14, FontWeight.w500, 1.6, c.textLight),
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: c.success.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                  color: c.success.withValues(alpha: 0.24)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppLucideIcons.wrench, size: 14, color: c.success),
                const SizedBox(width: 8),
                Text(
                  context.l10n.secureOnDevice,
                  style: _alex(12, FontWeight.w800, 1.2, c.success),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _HowItWorksPage extends StatelessWidget {
  const _HowItWorksPage();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    Widget maybeAnimate(Widget child, {Duration delay = Duration.zero}) {
      if (reduceMotion) return child;
      return child
          .animate(delay: delay)
          .fadeIn(duration: 380.ms, curve: Curves.easeOutCubic)
          .slideY(
              begin: 0.08,
              end: 0,
              duration: 380.ms,
              curve: Curves.easeOutCubic);
    }

    return ListView(
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      children: [
        const SizedBox(height: 16),
        Text(context.l10n.howItWorks,
            style: _alex(12, FontWeight.w800, 1.2, c.accent)),
        const SizedBox(height: 4),
        Text(context.l10n.smsToTx,
            style: _alex(24, FontWeight.w800, 1.3, c.textMain)),
        const SizedBox(height: 8),
        Text(context.l10n.howItWorksDesc,
            style: _alex(14, FontWeight.w500, 1.5, c.textLight)),
        const SizedBox(height: 24),
        GlassCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              maybeAnimate(const _MessageBubble(), delay: 80.ms),
              const SizedBox(height: 14),
              maybeAnimate(_FlowConnector(color: c.accent),
                  delay: 280.ms),
              const SizedBox(height: 14),
              maybeAnimate(const _ClassifiedTransactionCard(),
                  delay: 480.ms),
              const SizedBox(height: 14),
              maybeAnimate(const _HowItWorksNote(), delay: 640.ms),
            ],
          ),
        ),
      ],
    );
  }
}

class _HowItWorksNote extends StatelessWidget {
  const _HowItWorksNote();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final items = [
      context.l10n.howItWorksNote1,
      context.l10n.howItWorksNote2,
      context.l10n.howItWorksNote3,
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.success.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border:
            Border.all(color: c.success.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(AppLucideIcons.plus, size: 14, color: c.success),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(items[i],
                      style:
                          _alex(11, FontWeight.w800, 1.5, c.success)),
                ),
              ],
            ),
            if (i != items.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface2.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: c.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child:
                Icon(AppLucideIcons.receipt, size: 20, color: c.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.messageFromBank,
                    style:
                        _alex(12, FontWeight.w800, 1.2, c.textMain)),
                const SizedBox(height: 5),
                Text(
                  context.l10n.burgerBoutiqueSms,
                  style: _alex(12, FontWeight.w600, 1.4, c.textLight,
                      tabular: true),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FlowConnector extends StatelessWidget {
  const _FlowConnector({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
            width: 2,
            height: 18,
            color: color.withValues(alpha: 0.45)),
        Icon(AppLucideIcons.arrowLeftRight, color: color, size: 20),
        Container(
            width: 2,
            height: 18,
            color: color.withValues(alpha: 0.45)),
      ],
    );
  }
}

class _ClassifiedTransactionCard extends StatelessWidget {
  const _ClassifiedTransactionCard();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: c.primaryGradient,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: c.primary.withValues(alpha: 0.20),
            blurRadius: 22,
            spreadRadius: -12,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFFFF7A59),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(AppLucideIcons.utensilsCrossed,
                color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('BURGER BOUTIQUE',
                    style: _alex(
                        13, FontWeight.w800, 1.2, Colors.white)),
                const SizedBox(height: 5),
                Text(context.l10n.burgerBoutiqueSub,
                    style: _alex(
                        11,
                        FontWeight.w600,
                        1.2,
                        Colors.white.withValues(alpha: 0.72))),
              ],
            ),
          ),
          Text(
            context.l10n.burgerBoutiqueAmount,
            style: _alex(14, FontWeight.w800, 1.2, Colors.white,
                tabular: true),
          ),
        ],
      ),
    );
  }
}

class _PrivacyPage extends StatelessWidget {
  const _PrivacyPage();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      children: [
        const SizedBox(height: 16),
        Text(context.l10n.completePrivacy,
            style: _alex(12, FontWeight.w800, 1.2, c.accent)),
        const SizedBox(height: 4),
        Text(context.l10n.dataStaysOnDevice,
            style: _alex(24, FontWeight.w800, 1.3, c.textMain)),
        const SizedBox(height: 8),
        Text(context.l10n.privacyPrinciples,
            style: _alex(14, FontWeight.w500, 1.5, c.textLight)),
        const SizedBox(height: 24),
        Column(
          children: [
            _PrivacyTile(
                icon: Icons.memory_rounded,
                text: context.l10n.privacyRule1),
            const SizedBox(height: 12),
            _PrivacyTile(
                icon: Icons.visibility_off_rounded,
                text: context.l10n.privacyRule2),
            const SizedBox(height: 12),
            _PrivacyTile(
                icon: Icons.delete_forever_rounded,
                text: context.l10n.privacyRule3),
          ],
        ),
      ],
    );
  }
}

class _PrivacyTile extends StatelessWidget {
  const _PrivacyTile({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.success.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: c.success, size: 16),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(text,
                style: _alex(12, FontWeight.w800, 1.4, c.textMain)),
          ),
        ],
      ),
    );
  }
}

// ── Country page (S4) ───────────────────────────────────────────────────────

class _CountryPage extends ConsumerStatefulWidget {
  const _CountryPage();

  @override
  ConsumerState<_CountryPage> createState() => _CountryPageState();
}

class _CountryPageState extends ConsumerState<_CountryPage> {
  void _showCountryPicker(BuildContext context) {
    String searchQuery = '';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final c = context.colors;
            final selected = ref.read(onboardingSelectionProvider);
            final filteredCountries = onboardingCountries
                .where((country) =>
                    country.name.contains(searchQuery) ||
                    country.currency.contains(searchQuery) ||
                    country.currencyCode
                        .toLowerCase()
                        .contains(searchQuery.toLowerCase()))
                .toList();

            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                height: MediaQuery.of(context).size.height * 0.7,
                decoration: BoxDecoration(
                  color: c.bg.withValues(alpha: 0.95),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(24)),
                  border: Border(
                      top: BorderSide(color: c.border)),
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: c.border.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      context.l10n.selectCountryTitle,
                      style:
                          _alex(16, FontWeight.w800, 1.2, c.textMain),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: TextField(
                        onChanged: (val) =>
                            setModalState(() => searchQuery = val),
                        style:
                            _alex(13, FontWeight.w600, 1.2, c.textMain),
                        decoration: InputDecoration(
                          hintText:
                              context.l10n.searchCountryPlaceholder,
                          hintStyle: _alex(
                              12, FontWeight.w500, 1.2, c.textLight),
                          prefixIcon: Icon(Icons.search_rounded,
                              color: c.textLight, size: 18),
                          filled: true,
                          fillColor:
                              c.surface.withValues(alpha: 0.15),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide:
                                BorderSide(color: c.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide:
                                BorderSide(color: c.accent),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: filteredCountries.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final country = filteredCountries[i];
                          final isSelected = country.code == selected.code;
                          return _CountryTile(
                            option: country,
                            selected: isSelected,
                            onTap: () {
                              ref
                                  .read(onboardingSelectionProvider.notifier)
                                  .state = country;
                              setModalState(() {});
                              Navigator.pop(context);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final selectedCountry = ref.watch(onboardingSelectionProvider);

    return ListView(
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      children: [
        const SizedBox(height: 16),
        Text(context.l10n.easyToUse,
            style: _alex(12, FontWeight.w800, 1.2, c.accent)),
        const SizedBox(height: 4),
        Text(context.l10n.selectCountryCurrency,
            style: _alex(24, FontWeight.w800, 1.3, c.textMain)),
        const SizedBox(height: 8),
        Text(context.l10n.selectCountryDesc,
            style: _alex(14, FontWeight.w500, 1.5, c.textLight)),
        const SizedBox(height: 24),
        GlassCard(
          padding: const EdgeInsets.all(20),
          child: _SelectionTile(
            title: context.l10n.mainCountryCurrency,
            subtitle:
                '${selectedCountry.localizedName(context)} · ${selectedCountry.currencyCode} (${selectedCountry.localizedCurrency(context)})',
            icon: _FlagAvatar(code: selectedCountry.code, size: 36),
            onTap: () => _showCountryPicker(context),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

class _SelectionTile extends StatelessWidget {
  const _SelectionTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: c.surface.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: c.border.withValues(alpha: 0.08)),
        ),
        child: Row(
          children: [
            icon,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style:
                          _alex(13, FontWeight.w800, 1.2, c.textMain)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style:
                          _alex(11, FontWeight.w600, 1.3, c.textLight)),
                ],
              ),
            ),
            Icon(
              Directionality.of(context) == TextDirection.rtl
                  ? Icons.chevron_left_rounded
                  : Icons.chevron_right_rounded,
              color: c.textLight,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _FlagAvatar extends StatelessWidget {
  const _FlagAvatar({required this.code, this.size = 30});
  final String code;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.08),
      decoration: BoxDecoration(
        color: c.surface,
        shape: BoxShape.circle,
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.72)),
        boxShadow: [
          BoxShadow(
            color: c.primary.withValues(alpha: 0.12),
            blurRadius: 12,
            spreadRadius: -6,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipOval(
        child: SvgPicture.asset(
          'assets/flags/$code.svg',
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _CountryTile extends StatelessWidget {
  const _CountryTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final OnboardingCountry option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? c.accent.withValues(alpha: 0.12)
              : c.surface.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? c.accent.withValues(alpha: 0.36)
                : c.border,
          ),
        ),
        child: Row(
          children: [
            _FlagAvatar(code: option.code, size: 34),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(option.localizedName(context),
                      style:
                          _alex(12, FontWeight.w800, 1.2, c.textMain)),
                  const SizedBox(height: 4),
                  Text(option.localizedCurrency(context),
                      style:
                          _alex(10, FontWeight.w700, 1.2, c.textLight)),
                ],
              ),
            ),
            Text(
              option.currencyCode,
              style: _alex(11, FontWeight.w800, 1.2,
                  selected ? c.accent : c.textLight,
                  tabular: true),
            ),
          ],
        ),
      ),
    );
  }
}

class KsaFlagIcon extends StatelessWidget {
  const KsaFlagIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return const _FlagAvatar(code: 'sa', size: 40);
  }
}
