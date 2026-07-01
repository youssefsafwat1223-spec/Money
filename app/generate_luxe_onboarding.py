import re

with open("lib/features/onboarding/onboarding_screen.dart", "r") as f:
    content = f.read()

models_and_widgets = ""
idx = content.find("// ── Data models")
if idx != -1:
    models_and_widgets = content[idx:]

new_content = """import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../core/auth/auth_service.dart';
import '../../core/session/app_session.dart';
import '../../core/di/app_providers.dart';
import '../../data/catalog/catalog_daos.dart';
import '../../core/theme/app_assets.dart';
import '../../core/utils/l10n_ext.dart';
import '../common/app_button.dart';
import '../settings/settings_providers.dart';
import 'onboarding_options.dart';
import 'widgets/luxe_starry_bg.dart';

const _kGold = Color(0xFFDAA520);

TextStyle _alex(double size, FontWeight weight, double height, Color color,
    {bool tabular = false, List<Shadow>? shadows}) {
  return GoogleFonts.inter(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
    shadows: shadows,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  ).copyWith(
    fontFamilyFallback: [
      GoogleFonts.ibmPlexSansArabic().fontFamily!,
      GoogleFonts.alexandria().fontFamily!,
    ],
  );
}

class LuxeOnboardingScreen extends ConsumerStatefulWidget {
  const LuxeOnboardingScreen({super.key});

  @override
  ConsumerState<LuxeOnboardingScreen> createState() => _LuxeOnboardingScreenState();
}

class _LuxeOnboardingScreenState extends ConsumerState<LuxeOnboardingScreen> {
  final _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    _pageController.nextPage(
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOutCubic,
    );
  }

  Future<void> _finishFlow() async {
    final country = ref.read(onboardingSelectionProvider);
    if (country != null) {
      try {
        await ref
            .read(saveCountryCurrencyUseCaseProvider)
            .call(country.code, country.currencyCode);
      } catch (_) {}
    }
    if (mounted) context.go('/onboarding/method-picker');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const Positioned.fill(child: LuxeStarryBackground()),
          SafeArea(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _StorytellingPhase(onStoryFinished: _nextPage),
                _LanguageSelectionPhase(onNext: _nextPage),
                _CountrySelectionPhase(onNext: _finishFlow),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Phase 1: Storytelling & Auth ──────────────────────────────────────────────

class _StorytellingPhase extends ConsumerStatefulWidget {
  const _StorytellingPhase({required this.onStoryFinished});
  final VoidCallback onStoryFinished;

  @override
  ConsumerState<_StorytellingPhase> createState() => _StorytellingPhaseState();
}

class _StorytellingPhaseState extends ConsumerState<_StorytellingPhase> {
  bool _busy = false;
  bool _showEmail = false;
  final _emailController = TextEditingController();
  
  // Story state
  int _storyIndex = 0;
  bool _showAuth = false;
  Timer? _storyTimer;

  @override
  void initState() {
    super.initState();
    _startStory();
  }

  void _startStory() {
    _storyTimer = Timer.periodic(const Duration(milliseconds: 3500), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_storyIndex < 3) {
          _storyIndex++;
        } else {
          _showAuth = true;
          timer.cancel();
        }
      });
    });
  }

  @override
  void dispose() {
    _storyTimer?.cancel();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _provider(Future<AuthIdentity> Function() signIn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final identity = await signIn();
      final wasAuthenticated = AppSession.instance.status == SessionStatus.authenticated;
      final returningUser = AppSession.instance.hasCompletedOnboarding;
      await AppSession.instance.setIdentity(method: identity.method, email: identity.email);
      
      if (mounted) {
        if (wasAuthenticated) {
          context.go('/backup');
        } else if (returningUser) {
          context.go('/');
        } else {
          widget.onStoryFinished();
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر تسجيل الدخول الآن. حاول مرة أخرى.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.read(authServiceProvider);
    
    return Column(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 1200),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _buildStoryContent(),
          ),
        ),
        
        if (_showAuth)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1.5),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 30, offset: const Offset(0, 10))
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('ابدأ رحلتك الآن', textAlign: TextAlign.center, style: _alex(18, FontWeight.w800, 1.2, Colors.white)),
                      const SizedBox(height: 24),
                      if (_busy)
                        const Center(child: CircularProgressIndicator(color: _kGold))
                      else if (_showEmail)
                        _buildEmailInput(auth)
                      else ...[
                        SizedBox(
                          height: 54,
                          child: SignInWithAppleButton(
                            onPressed: () => _provider(auth.signInWithApple),
                            text: context.l10n.continueWithApple,
                            style: SignInWithAppleButtonStyle.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _providerButton(
                          iconWidget: const _GoogleMark(size: 20),
                          label: context.l10n.continueWithGoogle,
                          background: Colors.white,
                          foreground: Colors.black,
                          onTap: () => _provider(auth.signInWithGoogle),
                        ),
                        const SizedBox(height: 12),
                        _providerButton(
                          icon: Icons.mail_rounded,
                          label: 'المتابعة بالبريد الإلكتروني',
                          background: Colors.white.withValues(alpha: 0.1),
                          foreground: Colors.white,
                          border: true,
                          onTap: () => setState(() => _showEmail = true),
                        ),
                      ]
                    ],
                  ),
                ),
              ),
            ),
          ).animate().fade(duration: 800.ms).slideY(begin: 0.1, end: 0, curve: Curves.easeOutCubic),
      ],
    );
  }

  Widget _buildStoryContent() {
    if (_storyIndex == 0) {
      return Column(
        key: const ValueKey(0),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _LogoMark(),
          const SizedBox(height: 24),
          const _TypewriterText(text: 'قرش', size: 56, weight: FontWeight.w900, color: _kGold),
          const SizedBox(height: 12),
          const _TypewriterText(text: 'لنمو مالي ذكي وحياة أسهل.', size: 16, weight: FontWeight.w600, color: Colors.white),
        ],
      );
    } else if (_storyIndex == 1) {
      return Column(
        key: const ValueKey(1),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _TypewriterText(text: 'قرش تطبيق يساعدك تتحكم في مصروفاتك،', size: 16, weight: FontWeight.w500, color: Colors.white),
          const SizedBox(height: 8),
          const _TypewriterText(text: 'تخطط بذكاء، وتحقق أهدافك المالية', size: 16, weight: FontWeight.w500, color: Colors.white),
          const SizedBox(height: 8),
          const _TypewriterText(text: 'من خلال تقارير ذكية وتنبيهات لحظية،', size: 16, weight: FontWeight.w500, color: Colors.white),
          const SizedBox(height: 8),
          const _TypewriterText(text: 'وتجربة بسيطة صممت لك.', size: 16, weight: FontWeight.w500, color: Colors.white),
        ],
      );
    } else if (_storyIndex == 2) {
      return Column(
        key: const ValueKey(2),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _TypewriterText(text: 'نؤمن أن كل قرش له قيمة،', size: 16, weight: FontWeight.w500, color: _kGold),
          const SizedBox(height: 8),
          const _TypewriterText(text: 'ونحن هنا عشان نساعدك تستثمرها بحكمة.', size: 16, weight: FontWeight.w500, color: _kGold),
          const SizedBox(height: 48),
          Icon(Icons.favorite_rounded, color: _kGold, size: 24).animate().scale(delay: 1.seconds, duration: 500.ms, curve: Curves.elasticOut),
          const SizedBox(height: 16),
          const _TypewriterText(text: 'من فريق قرش،', size: 14, weight: FontWeight.w500, color: Colors.white70),
          const SizedBox(height: 4),
          const _TypewriterText(text: 'شكراً لأنك جزء من رحلتنا.', size: 14, weight: FontWeight.w500, color: Colors.white70),
        ],
      );
    } else {
      return Column(
        key: const ValueKey(3),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _TypewriterText(text: 'متحمسين نبدأ معك', size: 28, weight: FontWeight.w800, color: Colors.white),
          const SizedBox(height: 12),
          const _TypewriterText(text: 'لنكتب لك الخير ونساعدك تصنع فرقاً في حياتك.', size: 14, weight: FontWeight.w500, color: _kGold),
          const SizedBox(height: 48),
          const _TypewriterText(text: 'مع قرش ستحصل على:', size: 16, weight: FontWeight.w700, color: Colors.white),
          const SizedBox(height: 12),
          const _TypewriterText(text: 'تسجيل مصروفات ذكي • ميزانيات مرنة • تنبيهات فورية', size: 13, weight: FontWeight.w500, color: Colors.white70),
          const SizedBox(height: 8),
          const _TypewriterText(text: 'متابعة الاشتراكات • تقارير أسبوعية متطورة', size: 13, weight: FontWeight.w500, color: Colors.white70),
          const SizedBox(height: 8),
          const _TypewriterText(text: 'عروض وخصومات حصرية • وأكثر بكثير...', size: 13, weight: FontWeight.w500, color: Colors.white70),
        ],
      );
    }
  }

  Widget _buildEmailInput(AuthService auth) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          textDirection: TextDirection.ltr,
          style: _alex(15, FontWeight.w600, 1.4, Colors.white),
          decoration: InputDecoration(
            hintText: 'you@example.com',
            hintTextDirection: TextDirection.ltr,
            hintStyle: _alex(14, FontWeight.w400, 1.4, Colors.white.withValues(alpha: 0.4)),
            prefixIcon: Icon(Icons.mail_outline_rounded, color: Colors.white.withValues(alpha: 0.7)),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.1),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: _kGold, width: 1.5)),
          ),
        ),
        const SizedBox(height: 16),
        AppPrimaryButton(
          label: 'إرسال الرمز',
          loading: _busy,
          onTap: () async {
            final email = _emailController.text.trim();
            if (email.isEmpty) return;
            setState(() => _busy = true);
            try {
              await auth.sendEmailCode(email);
              if (mounted) context.push('/onboarding/otp', extra: email);
            } catch (_) {
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر إرسال الرمز.')));
            } finally {
              if (mounted) setState(() => _busy = false);
            }
          },
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => setState(() => _showEmail = false),
          child: Text('الرجوع', style: _alex(13, FontWeight.w600, 1.2, Colors.white.withValues(alpha: 0.7))),
        )
      ],
    ).animate().fade(duration: 400.ms).slideY(begin: 0.1, end: 0);
  }

  Widget _providerButton({IconData? icon, Widget? iconWidget, required String label, required Color background, required Color foreground, required VoidCallback onTap, bool border = false}) {
    return SizedBox(
      height: 54,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          backgroundColor: background,
          side: border ? BorderSide(color: Colors.white.withValues(alpha: 0.2)) : BorderSide.none,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            iconWidget ?? Icon(icon, color: foreground, size: 22),
            const SizedBox(width: 12),
            Text(label, style: _alex(15, FontWeight.w800, 1.2, foreground)),
          ],
        ),
      ),
    );
  }
}

// ── Phase 2: Language Selection ───────────────────────────────────────────────

class _LanguageSelectionPhase extends ConsumerStatefulWidget {
  const _LanguageSelectionPhase({required this.onNext});
  final VoidCallback onNext;

  @override
  ConsumerState<_LanguageSelectionPhase> createState() => _LanguageSelectionPhaseState();
}

class _LanguageSelectionPhaseState extends ConsumerState<_LanguageSelectionPhase> {
  String _selected = 'ar';
  
  Future<void> _continue() async {
    await ref.read(saveLanguageUseCaseProvider).call(_selected);
    refreshUserSettings(ref);
    widget.onNext();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _TypewriterText(text: 'اختر لغتك المفضلة', size: 24, weight: FontWeight.w800, color: Colors.white),
              const SizedBox(height: 12),
              const _TypewriterText(text: 'يمكنك تغيير اللغة من الإعدادات في أي وقت', size: 14, weight: FontWeight.w500, color: Colors.white70),
            ],
          ),
        ),
        
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1.5),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 30, offset: const Offset(0, 10))
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _LangCard(title: 'العربية', tag: 'RTL', selected: _selected == 'ar', onTap: () => setState(() => _selected = 'ar')),
                    const SizedBox(height: 16),
                    _LangCard(title: 'English', tag: 'LTR', selected: _selected == 'en', onTap: () => setState(() => _selected = 'en')),
                    const SizedBox(height: 24),
                    AppPrimaryButton(label: 'التالي', onTap: _continue),
                  ],
                ),
              ),
            ),
          ),
        ).animate().fade(duration: 800.ms).slideY(begin: 0.2, end: 0, curve: Curves.easeOutCubic),
      ],
    );
  }
}

class _LangCard extends StatelessWidget {
  const _LangCard({required this.title, required this.tag, required this.selected, required this.onTap});
  final String title;
  final String tag;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? _kGold.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? _kGold : Colors.white.withValues(alpha: 0.1), width: 1.5),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: _alex(18, FontWeight.w800, 1.2, Colors.white)),
                  const SizedBox(height: 4),
                  Text(tag, style: _alex(12, FontWeight.w600, 1.2, Colors.white.withValues(alpha: 0.5))),
                ],
              ),
            ),
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? _kGold : Colors.transparent,
                border: Border.all(color: selected ? _kGold : Colors.white.withValues(alpha: 0.2), width: 1.5),
              ),
              child: selected ? const Icon(Icons.check_rounded, size: 16, color: Colors.black) : null,
            ),
          ],
        ),
      ),
    );
  }
}


// ── Phase 3: Country Selection ────────────────────────────────────────────────

class _CountrySelectionPhase extends ConsumerStatefulWidget {
  const _CountrySelectionPhase({required this.onNext});
  final VoidCallback onNext;

  @override
  ConsumerState<_CountrySelectionPhase> createState() => _CountrySelectionPhaseState();
}

class _CountrySelectionPhaseState extends ConsumerState<_CountrySelectionPhase> {
  void _showCountryPicker(BuildContext context) {
    String searchQuery = '';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final selected = ref.read(onboardingSelectionProvider);
            final options = _countryOptions(
              ref.read(supportedCountriesProvider).valueOrNull ?? const <RemoteCountry>[],
              ref.read(activeCurrenciesProvider).valueOrNull ?? const <RemoteCurrency>[],
            );
            final normalizedSearch = searchQuery.trim().toLowerCase();
            final filteredCountries = options
                .where((country) =>
                    country.nameAr.contains(searchQuery) ||
                    country.nameEn.toLowerCase().contains(normalizedSearch) ||
                    country.currencyNameAr.contains(searchQuery) ||
                    country.currencyNameEn.toLowerCase().contains(normalizedSearch) ||
                    country.currencyCode.toLowerCase().contains(normalizedSearch))
                .toList();

            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                height: MediaQuery.of(context).size.height * 0.7,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4))),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TextField(
                        onChanged: (v) => setModalState(() => searchQuery = v),
                        style: _alex(14, FontWeight.w600, 1.2, Colors.white),
                        decoration: InputDecoration(
                          hintText: 'ابحث عن بلدك أو عملتك...',
                          hintStyle: _alex(14, FontWeight.w500, 1.2, Colors.white.withValues(alpha: 0.5)),
                          prefixIcon: Icon(Icons.search_rounded, color: Colors.white.withValues(alpha: 0.5)),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.1),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                        itemCount: filteredCountries.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final option = filteredCountries[index];
                          final isSelected = selected != null && option.code.toLowerCase() == selected.code.toLowerCase();
                          return _CountryTile(
                            option: option,
                            selected: isSelected,
                            onTap: () {
                              ref.read(onboardingSelectionProvider.notifier).state = option.toSelection();
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
    final options = _countryOptions(
      ref.watch(supportedCountriesProvider).valueOrNull ?? const <RemoteCountry>[],
      ref.watch(activeCurrenciesProvider).valueOrNull ?? const <RemoteCurrency>[],
    );
    final selectedCountry = ref.watch(onboardingSelectionProvider);
    final selectedOption = _selectedOption(options, selectedCountry);

    return Column(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _TypewriterText(text: 'اختر بلدك وعملتك', size: 24, weight: FontWeight.w800, color: Colors.white),
              const SizedBox(height: 12),
              const _TypewriterText(text: 'إعدادات سريعة لتخصيص تجربتك\nحسب منطقتك.', size: 14, weight: FontWeight.w500, color: Colors.white70),
            ],
          ),
        ),
        
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1.5),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 30, offset: const Offset(0, 10))
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('العملة', style: _alex(13, FontWeight.w700, 1.2, _kGold)),
                    const SizedBox(height: 8),
                    _DropdownField(
                      leading: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(color: _kGold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.payments_outlined, size: 18, color: _kGold),
                      ),
                      label: selectedOption == null
                          ? 'تحميل...'
                          : '${selectedOption.localizedCurrency(context)} (${selectedOption.currencyCode})',
                      onTap: options.isEmpty ? () {} : () => _showCountryPicker(context),
                    ),
                    const SizedBox(height: 24),
                    AppPrimaryButton(label: 'التالي', onTap: widget.onNext),
                  ],
                ),
              ),
            ),
          ),
        ).animate().fade(duration: 800.ms).slideY(begin: 0.2, end: 0, curve: Curves.easeOutCubic),
      ],
    );
  }

  List<_CountryOption> _countryOptions(List<RemoteCountry> countries, List<RemoteCurrency> currencies) {
    final options = [
      for (final country in countries)
        if (_preferredCurrency(country, currencies) != null)
          _CountryOption(country: country, currency: _preferredCurrency(country, currencies)!),
    ];
    options.sort((a, b) {
      if (a.code == 'sa') return -1;
      if (b.code == 'sa') return 1;
      return a.localizedSortKey.compareTo(b.localizedSortKey);
    });
    return options;
  }

  RemoteCurrency? _preferredCurrency(RemoteCountry country, List<RemoteCurrency> currencies) {
    final code = country.code.trim().toUpperCase();
    for (final currency in currencies) {
      if (currency.countryCodes.contains(code)) return currency;
    }
    return null;
  }

  _CountryOption? _selectedOption(List<_CountryOption> options, OnboardingCountry? selected) {
    if (selected == null) return options.isEmpty ? null : options.first;
    for (final option in options) {
      if (option.code.toLowerCase() == selected.code.toLowerCase()) return option;
    }
    return options.isEmpty ? null : options.first;
  }
}

// ── Shared UI widgets ─────────────────────────────────────────────────────────

class _TypewriterText extends StatefulWidget {
  const _TypewriterText({required this.text, required this.size, required this.weight, required this.color});
  final String text;
  final double size;
  final FontWeight weight;
  final Color color;

  @override
  State<_TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<_TypewriterText> {
  int _chars = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Fast typing speed
    _timer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_chars < widget.text.length) {
        setState(() => _chars++);
      } else {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final display = widget.text.substring(0, _chars);
    return Text(
      display,
      textAlign: TextAlign.center,
      style: _alex(widget.size, widget.weight, 1.4, widget.color),
    );
  }
}

class _LogoMark extends StatelessWidget {
  const _LogoMark();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 70,
      height: 70,
      decoration: BoxDecoration(
        color: _kGold,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Icon(Icons.favorite_rounded, color: Colors.black, size: 36),
      ),
    ).animate().scale(duration: 800.ms, curve: Curves.elasticOut);
  }
}

"""

with open("lib/features/onboarding/luxe_onboarding_screen.dart", "w") as f:
    f.write(new_content)
    f.write(models_and_widgets)

