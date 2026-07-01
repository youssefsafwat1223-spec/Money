import re

with open("lib/features/onboarding/onboarding_screen.dart", "r") as f:
    content = f.read()

# We want to extract the Data models and Shared UI widgets
# Everything from "// ── Data models" to the end.
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
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/l10n_ext.dart';
import '../common/app_button.dart';
import 'onboarding_options.dart';
import 'widgets/luxe_mesh_gradient.dart';

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

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  int _currentIndex = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goToCountrySelection() {
    _pageController.nextPage(
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOutCubic,
    );
  }

  Future<void> _finishCountrySelection() async {
    final country = ref.read(onboardingSelectionProvider);
    if (country == null) return;
    try {
      await ref
          .read(saveCountryCurrencyUseCaseProvider)
          .call(country.code, country.currencyCode);
    } catch (_) {}
    if (mounted) context.go('/onboarding/method-picker');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const Positioned.fill(child: LuxeMeshGradient()),
          SafeArea(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (i) => setState(() => _currentIndex = i),
              children: [
                _LuxeWelcomeAuth(onAuthenticatedNewUser: _goToCountrySelection),
                _LuxeCountrySelection(onNext: _finishCountrySelection),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Page 1: Cinematic Welcome & Auth (Glassmorphism) ──────────────────────────

class _LuxeWelcomeAuth extends ConsumerStatefulWidget {
  const _LuxeWelcomeAuth({required this.onAuthenticatedNewUser});
  final VoidCallback onAuthenticatedNewUser;

  @override
  ConsumerState<_LuxeWelcomeAuth> createState() => _LuxeWelcomeAuthState();
}

class _LuxeWelcomeAuthState extends ConsumerState<_LuxeWelcomeAuth> {
  bool _busy = false;
  bool _showEmail = false;
  final _emailController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _provider(Future<AuthIdentity> Function() signIn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final identity = await signIn();
      final wasAuthenticated =
          AppSession.instance.status == SessionStatus.authenticated;
      final returningUser = AppSession.instance.hasCompletedOnboarding;
      await AppSession.instance
          .setIdentity(method: identity.method, email: identity.email);
      
      if (mounted) {
        if (wasAuthenticated) {
          context.go('/backup');
        } else if (returningUser) {
          context.go('/');
        } else {
          widget.onAuthenticatedNewUser();
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر تسجيل الدخول الآن. حاول مرة أخرى.'),
          ),
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
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _GlowingLogo().animate().scale(
                    begin: const Offset(0.45, 0.45),
                    duration: 900.ms,
                    curve: Curves.elasticOut,
                  ).fade(duration: 500.ms),
              const SizedBox(height: 24),
              const _TypewriterTitle(),
              const SizedBox(height: 12),
              Text(
                'لنمو مالي ذكي وحياة أسهل.',
                textAlign: TextAlign.center,
                style: _alex(16, FontWeight.w600, 1.4, _kGold.withValues(alpha: 0.9)),
              )
                  .animate(delay: 1500.ms)
                  .fade(duration: 600.ms)
                  .slideY(begin: 0.30, end: 0, duration: 600.ms, curve: Curves.easeOut),
            ],
          ),
        ),
        
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.1),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 30,
                offset: const Offset(0, 10),
              )
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
                    Text(
                      'ابدأ رحلتك الآن',
                      textAlign: TextAlign.center,
                      style: _alex(18, FontWeight.w800, 1.2, Colors.white),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'اختر طريقة الدخول لبدء التحكم في أموالك',
                      textAlign: TextAlign.center,
                      style: _alex(13, FontWeight.w500, 1.5, Colors.white.withValues(alpha: 0.6)),
                    ),
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
        ).animate(delay: 2000.ms).fade(duration: 800.ms).slideY(begin: 0.2, end: 0, curve: Curves.easeOutCubic),
      ],
    );
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
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: _kGold, width: 1.5),
            ),
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
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('تعذر إرسال الرمز.')),
                );
              }
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

  Widget _providerButton({
    IconData? icon,
    Widget? iconWidget,
    required String label,
    required Color background,
    required Color foreground,
    required VoidCallback onTap,
    bool border = false,
  }) {
    return SizedBox(
      height: 54,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          backgroundColor: background,
          side: border
              ? BorderSide(color: Colors.white.withValues(alpha: 0.2))
              : BorderSide.none,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            iconWidget ?? Icon(icon, color: foreground, size: 22),
            const SizedBox(width: 12),
            Text(
              label,
              style: _alex(15, FontWeight.w800, 1.2, foreground),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Page 2: Luxe Country Selection ──────────────────────────────────────────────

class _LuxeCountrySelection extends ConsumerStatefulWidget {
  const _LuxeCountrySelection({required this.onNext});
  final VoidCallback onNext;

  @override
  ConsumerState<_LuxeCountrySelection> createState() => _LuxeCountrySelectionState();
}

class _LuxeCountrySelectionState extends ConsumerState<_LuxeCountrySelection> {
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
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
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
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
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
              const _GlowingLogo().animate().scale(begin: const Offset(0.45, 0.45), duration: 900.ms, curve: Curves.elasticOut),
              const SizedBox(height: 24),
              Text(
                'اختر بلدك وعملتك',
                textAlign: TextAlign.center,
                style: _alex(24, FontWeight.w800, 1.2, Colors.white),
              ).animate().fade(duration: 600.ms).slideY(begin: 0.2, end: 0, curve: Curves.easeOut),
              const SizedBox(height: 12),
              Text(
                'إعدادات سريعة لتخصيص تجربتك\nحسب منطقتك.',
                textAlign: TextAlign.center,
                style: _alex(14, FontWeight.w500, 1.5, Colors.white.withValues(alpha: 0.7)),
              ).animate(delay: 200.ms).fade(duration: 600.ms),
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
                        decoration: BoxDecoration(
                          color: _kGold.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.payments_outlined, size: 18, color: _kGold),
                      ),
                      label: selectedOption == null
                          ? 'تحميل...'
                          : '${selectedOption.localizedCurrency(context)} (${selectedOption.currencyCode})',
                      onTap: options.isEmpty ? () {} : () => _showCountryPicker(context),
                    ),
                    const SizedBox(height: 24),
                    AppPrimaryButton(
                      label: 'التالي',
                      onTap: widget.onNext,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ).animate(delay: 400.ms).fade(duration: 800.ms).slideY(begin: 0.2, end: 0, curve: Curves.easeOutCubic),
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

class _DropdownField extends StatelessWidget {
  const _DropdownField({required this.leading, required this.label, required this.onTap});
  final Widget leading;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 14),
            Expanded(
              child: Text(label, style: _alex(15, FontWeight.w700, 1.2, Colors.white)),
            ),
            Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white.withValues(alpha: 0.4), size: 22),
          ],
        ),
      ),
    );
  }
}

class _GlowingLogo extends StatelessWidget {
  const _GlowingLogo();
  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 160,
          height: 160,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [Color(0x66DAA520), Color(0x00DAA520)],
              radius: 0.75,
            ),
          ),
        ).animate(onPlay: (c) => c.repeat(reverse: true)).fade(begin: 0.2, end: 0.9, duration: 2200.ms),
        Image.asset(AppAssets.getCoin(context), width: 100, height: 100),
      ],
    );
  }
}

class _TypewriterTitle extends StatefulWidget {
  const _TypewriterTitle();
  @override
  State<_TypewriterTitle> createState() => _TypewriterTitleState();
}

class _TypewriterTitleState extends State<_TypewriterTitle> {
  static const _text = 'قـرش';
  int _chars = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 900), _tick);
  }

  void _tick() {
    if (!mounted || _chars >= _text.length) return;
    setState(() => _chars++);
    _timer = Timer(const Duration(milliseconds: 170), _tick);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final display = _chars == 0 ? '' : _text.substring(0, _chars);
    return SizedBox(
      height: 64,
      child: Text(
        display,
        textAlign: TextAlign.center,
        style: _alex(56, FontWeight.w900, 1.1, _kGold),
      ),
    );
  }
}

class _GoogleMark extends StatelessWidget {
  const _GoogleMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final stroke = size * 0.18;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _GoogleMarkPainter(strokeWidth: stroke),
          ),
          Positioned(
            right: size * 0.08,
            child: Container(
              width: size * 0.34,
              height: stroke,
              decoration: BoxDecoration(
                color: const Color(0xFF4285F4),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GoogleMarkPainter extends CustomPainter {
  const _GoogleMarkPainter({required this.strokeWidth});

  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = (size.shortestSide - strokeWidth) / 2;

    void drawArc(Color color, double startAngle, double sweepAngle) {
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        paint,
      );
    }

    drawArc(const Color(0xFFEA4335), 2.45, 1.25);
    drawArc(const Color(0xFFFBBC05), 3.75, 1.0);
    drawArc(const Color(0xFF34A853), 4.8, 1.2);
    drawArc(const Color(0xFF4285F4), 6.05, 1.55);
  }

  @override
  bool shouldRepaint(covariant _GoogleMarkPainter oldDelegate) {
    return oldDelegate.strokeWidth != strokeWidth;
  }
}

"""

with open("lib/features/onboarding/onboarding_screen.dart", "w") as f:
    f.write(new_content)
    f.write(models_and_widgets)

