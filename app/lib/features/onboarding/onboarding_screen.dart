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

TextStyle _alex(double size, FontWeight weight, double height, Color color, {bool tabular = false, List<Shadow>? shadows}) {
  return GoogleFonts.alexandria(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
    shadows: shadows,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  );
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageController = PageController();
  int _currentIndex = 0;
  static const int _pageCount = 6;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _next() {
    if (_currentIndex < _pageCount - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    } else {
      context.go('/onboarding/auth');
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
                _SmsPage(),
                _HowItWorksPage(),
                _VaultPage(),
                _CountryPage(),
                _PrivacyPage(),
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
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter, vertical: AppSpacing.s3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
  const _BottomBar({required this.index, required this.count, required this.onNext});
  
  final int index;
  final int count;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isLast = index == count - 1;
    
    const actionGradient = LinearGradient(
      colors: [Color(0xFFFFB300), Color(0xFFFF9500)],
      begin: Alignment.topRight,
      end: Alignment.bottomLeft,
    );
    final actionForeground = c.primary;
    
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        16,
        AppSpacing.gutter,
        28,
      ),
      decoration: const BoxDecoration(
        color: Colors.transparent,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.center,
            child: Container(
              height: 54,
              width: isLast ? 195 : 150,
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(27)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      isLast ? context.l10n.registerAndStart : context.l10n.next,
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
        ],
      ),
    );
  }
}

// ==========================================
// PAGES IMPLEMENTATION
// ==========================================

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: c.success.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: c.success.withValues(alpha: 0.24)),
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

class _SmsPage extends StatelessWidget {
  const _SmsPage();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      children: [
        const SizedBox(height: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.effortless,
              style: _alex(12, FontWeight.w800, 1.2, c.accent),
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.noTyping,
              style: _alex(24, FontWeight.w800, 1.3, c.textMain),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.smsReadingDesc,
              style: _alex(14, FontWeight.w500, 1.5, c.textLight),
            ),
          ],
        ),
        const SizedBox(height: 24),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _SmsTile(
                bank: 'SNB',
                time: context.l10n.now,
                content: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: context.l10n.snbSmsText),
                      TextSpan(
                        text: '18.50 ${context.l10n.sar}',
                        style: _alex(12, FontWeight.w800, 1.4, c.accent),
                      ),
                      TextSpan(text: context.l10n.snbSmsSuffix),
                    ],
                  ),
                  style: _alex(12, FontWeight.w500, 1.4, c.textLight),
                ),
                isActive: false,
              ),
              const SizedBox(height: 12),
              _SmsTile(
                bank: context.l10n.alrajhi,
                time: context.l10n.oneMinuteAgo,
                content: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: context.l10n.alrajhiSmsText),
                      TextSpan(
                        text: '126.00 ${context.l10n.sar}',
                        style: _alex(12, FontWeight.w800, 1.4, c.success),
                      ),
                      TextSpan(text: context.l10n.alrajhiSmsSuffix),
                    ],
                  ),
                  style: _alex(12, FontWeight.w500, 1.4, c.textLight),
                ),
                isActive: true,
              ),
              const SizedBox(height: 16),
              Divider(color: c.border.withValues(alpha: 0.15), height: 1),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.memory_rounded, size: 14, color: c.success),
                      const SizedBox(width: 4),
                      Text(
                        context.l10n.localProcessing,
                        style: _alex(11, FontWeight.w700, 1.2, c.success),
                      ),
                    ],
                  ),
                  Text(
                    context.l10n.privacyFirst,
                    style: _alex(11, FontWeight.w700, 1.2, c.textLight),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SmsTile extends StatelessWidget {
  const _SmsTile({
    required this.bank,
    required this.time,
    required this.content,
    required this.isActive,
  });
  
  final String bank;
  final String time;
  final Widget content;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isActive 
            ? c.accent.withValues(alpha: 0.05) 
            : c.surface.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive ? c.accent : Colors.white.withValues(alpha: 0.1),
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              gradient: c.primaryGradient,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.sms_outlined, size: 14, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(bank, style: _alex(13, FontWeight.w800, 1.2, c.textMain)),
                    Text(time, style: _alex(11, FontWeight.w600, 1.2, c.textLight)),
                  ],
                ),
                const SizedBox(height: 4),
                content,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HowItWorksPage extends StatelessWidget {
  const _HowItWorksPage();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    Widget maybeAnimate(Widget child, {Duration delay = Duration.zero}) {
      if (reduceMotion) return child;
      return child
          .animate(delay: delay)
          .fadeIn(duration: 380.ms, curve: Curves.easeOutCubic)
          .slideY(begin: 0.08, end: 0, duration: 380.ms, curve: Curves.easeOutCubic);
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      children: [
        const SizedBox(height: 16),
        Text(
          context.l10n.howItWorks,
          style: _alex(12, FontWeight.w800, 1.2, c.accent),
        ),
        const SizedBox(height: 4),
        Text(
          context.l10n.smsToTx,
          style: _alex(24, FontWeight.w800, 1.3, c.textMain),
        ),
        const SizedBox(height: 8),
        Text(
          context.l10n.howItWorksDesc,
          style: _alex(14, FontWeight.w500, 1.5, c.textLight),
        ),
        const SizedBox(height: 24),
        GlassCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              maybeAnimate(const _MessageBubble(), delay: 80.ms),
              const SizedBox(height: 14),
              maybeAnimate(_FlowConnector(color: c.accent), delay: 280.ms),
              const SizedBox(height: 14),
              maybeAnimate(const _ClassifiedTransactionCard(), delay: 480.ms),
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
        border: Border.all(color: c.success.withValues(alpha: 0.22)),
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
                  child: Text(
                    items[i],
                    style: _alex(11, FontWeight.w800, 1.5, c.success),
                  ),
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
            child: Icon(AppLucideIcons.receipt, size: 20, color: c.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.messageFromBank, style: _alex(12, FontWeight.w800, 1.2, c.textMain)),
                const SizedBox(height: 5),
                Text(
                  context.l10n.burgerBoutiqueSms,
                  style: _alex(12, FontWeight.w600, 1.4, c.textLight, tabular: true),
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
        Container(width: 2, height: 18, color: color.withValues(alpha: 0.45)),
        Icon(AppLucideIcons.arrowLeftRight, color: color, size: 20),
        Container(width: 2, height: 18, color: color.withValues(alpha: 0.45)),
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
            child: const Icon(AppLucideIcons.utensilsCrossed, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('BURGER BOUTIQUE', style: _alex(13, FontWeight.w800, 1.2, Colors.white)),
                const SizedBox(height: 5),
                Text(context.l10n.burgerBoutiqueSub, style: _alex(11, FontWeight.w600, 1.2, Colors.white.withValues(alpha: 0.72))),
              ],
            ),
          ),
          Text(
            context.l10n.burgerBoutiqueAmount,
            style: _alex(14, FontWeight.w800, 1.2, Colors.white, tabular: true),
          ),
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
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      children: [
        const SizedBox(height: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.financialMotivation,
              style: _alex(12, FontWeight.w800, 1.2, c.accent),
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.saveLikeGame,
              style: _alex(24, FontWeight.w800, 1.3, c.textMain),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.saveLikeGameDesc,
              style: _alex(14, FontWeight.w500, 1.5, c.textLight),
            ),
          ],
        ),
        const SizedBox(height: 24),
        GlassCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.totalSavings,
                        style: _alex(13, FontWeight.w700, 1.2, c.textLight),
                      ),
                      const SizedBox(height: 6),
                      Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(text: '11,250 '),
                            TextSpan(
                              text: context.l10n.sar,
                              style: _alex(14, FontWeight.w600, 1, c.textMain),
                            ),
                          ],
                        ),
                        style: _alex(32, FontWeight.w800, 1.2, c.textMain),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: c.success.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.savings_outlined, color: c.success, size: 24),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: c.surface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.flight_takeoff_rounded, size: 16, color: c.textMain),
                            const SizedBox(width: 8),
                            Text(
                              context.l10n.travelVault,
                              style: _alex(13, FontWeight.w800, 1.2, c.textMain),
                            ),
                          ],
                        ),
                        Text(
                          context.l10n.completedPercent,
                          style: _alex(12, FontWeight.w800, 1.2, c.success),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: 0.75,
                        backgroundColor: Colors.white.withValues(alpha: 0.1),
                        color: c.success,
                        minHeight: 8,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          context.l10n.goalLimit,
                          style: _alex(11, FontWeight.w600, 1.2, c.textLight),
                        ),
                        Text(
                          context.l10n.remainingAmount,
                          style: _alex(11, FontWeight.w600, 1.2, c.textLight),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}



class _CountryPage extends ConsumerStatefulWidget {
  const _CountryPage();

  @override
  ConsumerState<_CountryPage> createState() => _CountryPageState();
}

class _CountryPageState extends ConsumerState<_CountryPage> {
  int _selectedCountryIndex = 0;
  final Set<String> _selectedExtraCurrencies = {};
  final Set<String> _selectedSubscriptions = {};

  Future<void> _selectCountry(int index) async {
    setState(() => _selectedCountryIndex = index);
    final selectedCountry = onboardingCountries[index];
    try {
      final repository = ref.read(userSettingsRepositoryProvider);
      final settings = await repository.getSettings();
      await repository.saveSettings(
        settings.copyWith(
          country: selectedCountry.code,
          currency: selectedCountry.currencyCode,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لم نتمكن من حفظ البلد والعملة الآن. جرّب مرة أخرى.'),
        ),
      );
    }
  }

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
            final filteredCountries = onboardingCountries.where((country) =>
              country.name.contains(searchQuery) ||
              country.currency.contains(searchQuery) ||
              country.currencyCode.toLowerCase().contains(searchQuery.toLowerCase())
            ).toList();

            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                height: MediaQuery.of(context).size.height * 0.7,
                decoration: BoxDecoration(
                  color: c.bg.withValues(alpha: 0.95),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  border: Border(top: BorderSide(color: c.border)),
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
                      style: _alex(16, FontWeight.w800, 1.2, c.textMain),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: TextField(
                        onChanged: (val) => setModalState(() => searchQuery = val),
                        style: _alex(13, FontWeight.w600, 1.2, c.textMain),
                        decoration: InputDecoration(
                          hintText: context.l10n.searchCountryPlaceholder,
                          hintStyle: _alex(12, FontWeight.w500, 1.2, c.textLight),
                          prefixIcon: Icon(Icons.search_rounded, color: c.textLight, size: 18),
                          filled: true,
                          fillColor: c.surface.withValues(alpha: 0.15),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: c.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: c.accent),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: filteredCountries.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final country = filteredCountries[i];
                          final actualIndex = onboardingCountries.indexOf(country);
                          final isSelected = actualIndex == _selectedCountryIndex;
                          return _CountryTile(
                            option: country,
                            selected: isSelected,
                            onTap: () {
                              _selectCountry(actualIndex);
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

  void _showExtraCurrenciesPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final c = context.colors;
            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                height: MediaQuery.of(context).size.height * 0.6,
                decoration: BoxDecoration(
                  color: c.bg.withValues(alpha: 0.95),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  border: Border(top: BorderSide(color: c.border)),
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
                      context.l10n.additionalCurrenciesTitle,
                      style: _alex(16, FontWeight.w800, 1.2, c.textMain),
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        context.l10n.additionalCurrenciesDesc,
                        textAlign: TextAlign.center,
                        style: _alex(11, FontWeight.w600, 1.4, c.textLight),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: onboardingCurrencies.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final currency = onboardingCurrencies[i];
                          final isSelected = _selectedExtraCurrencies.contains(currency.code);
                          return _CurrencyTile(
                            option: currency,
                            selected: isSelected,
                            onTap: () {
                              setState(() {
                                if (isSelected) {
                                  _selectedExtraCurrencies.remove(currency.code);
                                } else {
                                  _selectedExtraCurrencies.add(currency.code);
                                }
                              });
                              setModalState(() {});
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

  void _showSubscriptionsPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final c = context.colors;
            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                height: MediaQuery.of(context).size.height * 0.6,
                decoration: BoxDecoration(
                  color: c.bg.withValues(alpha: 0.95),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  border: Border(top: BorderSide(color: c.border)),
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
                      context.l10n.expectedSubscriptions,
                      style: _alex(16, FontWeight.w800, 1.2, c.textMain),
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        context.l10n.expectedSubscriptionsDesc,
                        textAlign: TextAlign.center,
                        style: _alex(11, FontWeight.w600, 1.4, c.textLight),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: subscriptionShowcase.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final sub = subscriptionShowcase[i];
                          final isSelected = _selectedSubscriptions.contains(sub.asset);
                          return _SubscriptionSelectionTile(
                            option: sub,
                            selected: isSelected,
                            onTap: () {
                              setState(() {
                                if (isSelected) {
                                  _selectedSubscriptions.remove(sub.asset);
                                } else {
                                  _selectedSubscriptions.add(sub.asset);
                                }
                              });
                              setModalState(() {});
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
    final selectedCountry = onboardingCountries[_selectedCountryIndex];
    
    final extraCurrenciesText = _selectedExtraCurrencies.isEmpty 
        ? context.l10n.none 
        : _selectedExtraCurrencies.join('، ');

    final activeSubsNames = subscriptionShowcase
        .where((sub) => _selectedSubscriptions.contains(sub.asset))
        .map((sub) => sub.name)
        .toList();
    final subscriptionsText = activeSubsNames.isEmpty 
        ? context.l10n.noActiveSubs 
        : activeSubsNames.join('، ');

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      children: [
        const SizedBox(height: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.easyToUse,
              style: _alex(12, FontWeight.w800, 1.2, c.accent),
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.selectCountryCurrency,
              style: _alex(24, FontWeight.w800, 1.3, c.textMain),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.selectCountryDesc,
              style: _alex(14, FontWeight.w500, 1.5, c.textLight),
            ),
          ],
        ),
        const SizedBox(height: 24),
        GlassCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SelectionTile(
                title: context.l10n.mainCountryCurrency,
                subtitle: '${selectedCountry.localizedName(context)} · ${selectedCountry.currencyCode} (${selectedCountry.localizedCurrency(context)})',
                icon: _FlagAvatar(code: selectedCountry.code, size: 36),
                onTap: () => _showCountryPicker(context),
              ),
              const SizedBox(height: 12),
              _SelectionTile(
                title: context.l10n.additionalCurrencies,
                subtitle: extraCurrenciesText,
                icon: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: c.accent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.currency_exchange_rounded, color: c.accent, size: 18),
                ),
                onTap: () => _showExtraCurrenciesPicker(context),
              ),
              const SizedBox(height: 12),
              _SelectionTile(
                title: context.l10n.activeSubscriptions,
                subtitle: subscriptionsText,
                icon: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: c.accent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.subscriptions_outlined, color: c.accent, size: 18),
                ),
                onTap: () => _showSubscriptionsPicker(context),
              ),
            ],
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
          border: Border.all(color: c.border.withValues(alpha: 0.08)),
        ),
        child: Row(
          children: [
            icon,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: _alex(13, FontWeight.w800, 1.2, c.textMain),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: _alex(11, FontWeight.w600, 1.3, c.textLight),
                  ),
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

class _SubscriptionSelectionTile extends StatelessWidget {
  const _SubscriptionSelectionTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final SubscriptionShowcase option;
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
            color: selected ? c.accent.withValues(alpha: 0.36) : c.border,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: option.brandColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: SvgPicture.asset(
                'assets/brands/${option.asset}.svg',
                width: 22,
                height: 22,
                colorFilter: ColorFilter.mode(option.brandColor, BlendMode.srcIn),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(option.name, style: _alex(12, FontWeight.w800, 1.2, c.textMain)),
                  const SizedBox(height: 4),
                  Text(option.localizedPrice(context), style: _alex(10, FontWeight.w700, 1.2, c.textLight, tabular: true)),
                ],
              ),
            ),
            Checkbox(
              value: selected,
              onChanged: (_) => onTap(),
              activeColor: c.accent,
              checkColor: c.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
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
        border: Border.all(color: Colors.white.withValues(alpha: 0.72)),
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
            color: selected ? c.accent.withValues(alpha: 0.36) : c.border,
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
                  Text(option.localizedName(context), style: _alex(12, FontWeight.w800, 1.2, c.textMain)),
                  const SizedBox(height: 4),
                  Text(option.localizedCurrency(context), style: _alex(10, FontWeight.w700, 1.2, c.textLight)),
                ],
              ),
            ),
            Text(
              option.currencyCode,
              style: _alex(11, FontWeight.w800, 1.2, selected ? c.accent : c.textLight, tabular: true),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrencyTile extends StatelessWidget {
  const _CurrencyTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final OnboardingCurrency option;
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
          color: c.accent.withValues(alpha: selected ? 0.16 : 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.accent.withValues(alpha: selected ? 0.34 : 0.16)),
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: selected ? c.accent : c.surface2,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Text(
                option.code.characters.first,
                style: _alex(12, FontWeight.w800, 1.2, selected ? c.primary : c.textLight),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(option.localizedName(context), style: _alex(12, FontWeight.w800, 1.2, c.textMain)),
            ),
            Text(
              option.code,
              style: _alex(11, FontWeight.w800, 1.2, selected ? c.accent : c.textLight, tabular: true),
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

class _PrivacyPage extends StatelessWidget {
  const _PrivacyPage();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      children: [
        const SizedBox(height: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.completePrivacy,
              style: _alex(12, FontWeight.w800, 1.2, c.accent),
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.dataStaysOnDevice,
              style: _alex(24, FontWeight.w800, 1.3, c.textMain),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.privacyPrinciples,
              style: _alex(14, FontWeight.w500, 1.5, c.textLight),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Column(
          children: [
            _PrivacyTile(
              icon: Icons.memory_rounded,
              text: context.l10n.privacyRule1,
            ),
            const SizedBox(height: 12),
            _PrivacyTile(
              icon: Icons.visibility_off_rounded,
              text: context.l10n.privacyRule2,
            ),
            const SizedBox(height: 12),
            _PrivacyTile(
              icon: Icons.delete_forever_rounded,
              text: context.l10n.privacyRule3,
            ),
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
            child: Text(
              text,
              style: _alex(12, FontWeight.w800, 1.4, c.textMain),
            ),
          ),
        ],
      ),
    );
  }
}
