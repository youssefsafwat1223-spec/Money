import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../core/auth/auth_service.dart';
import '../../core/di/app_providers.dart';
import '../../core/backup/backup_service.dart';
import '../../core/session/app_session.dart';
import '../../core/utils/l10n_ext.dart';
import '../../data/catalog/catalog_daos.dart';
import '../common/app_button.dart';
import '../settings/settings_providers.dart';
import 'onboarding_options.dart';
import 'widgets/luxe_starry_bg.dart';
import '../../core/theme/app_assets.dart';

import '../../core/security/app_lock_service.dart';
import '../capture/services/local_notification_service.dart';

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
  const LuxeOnboardingScreen({
    super.key,
    this.skipStory = false,
    this.initialPage = 0,
  });

  final bool skipStory;
  final int initialPage;

  @override
  ConsumerState<LuxeOnboardingScreen> createState() =>
      _LuxeOnboardingScreenState();
}

class _LuxeOnboardingScreenState extends ConsumerState<LuxeOnboardingScreen> {
  late final PageController _pageController;
  double _bgOffset = 0.0;

  @override
  void initState() {
    super.initState();
    _bgOffset = widget.initialPage.toDouble();
    _pageController = PageController(initialPage: widget.initialPage);
    _pageController.addListener(() {
      if (_pageController.hasClients) {
        setState(() {
          _bgOffset = _pageController.page ?? 0.0;
        });
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    _pageController.nextPage(
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeInOutCubic,
    );
  }

  void _onCountryFinished() {
    _nextPage();
  }

  void _onProfileFinished() {
    if (Platform.isIOS) {
      _nextPage();
    } else {
      _finishFlow(nextRoute: '/onboarding/method-picker');
    }
  }

  Future<void> _finishFlow({
    String nextRoute = '/onboarding/method-picker',
    bool finishOnboarding = false,
  }) async {
    final country = ref.read(onboardingSelectionProvider);
    if (country != null) {
      try {
        await ref
            .read(saveCountryCurrencyUseCaseProvider)
            .call(country.code, country.currencyCode);
      } catch (_) {}
    }
    final dateOfBirth = ref.read(onboardingDateOfBirthProvider);
    if (dateOfBirth != null) {
      try {
        await ref.read(saveDateOfBirthUseCaseProvider).call(dateOfBirth);
      } catch (_) {}
    }
    if (!mounted) return;
    if (finishOnboarding) {
      await AppSession.instance.finishOnboarding();
      if (mounted) context.go('/');
      return;
    }
    context.go(nextRoute);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: LuxeStarryBackground(offset: _bgOffset)),
          SafeArea(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _StorytellingPhase(skipStory: widget.skipStory),
                _GoalsPhase(onNext: _nextPage),
                _BiometricsPhase(onNext: _nextPage),
                _NotificationsPhase(onNext: _nextPage),
                _LanguageSelectionPhase(onNext: _nextPage),
                _CountrySelectionPhase(onNext: _onCountryFinished),
                _DateOfBirthPhase(onNext: _onProfileFinished),
                if (Platform.isIOS) ...[
                  _IosShortcutPhase(
                    onNext: () => _finishFlow(finishOnboarding: true),
                  ),
                ]
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
  final bool skipStory;
  const _StorytellingPhase({this.skipStory = false});

  @override
  ConsumerState<_StorytellingPhase> createState() => _StorytellingPhaseState();
}

class _StorytellingPhaseState extends ConsumerState<_StorytellingPhase> {
  bool _busy = false;
  final _emailController = TextEditingController();
  final FocusNode _emailFocusNode = FocusNode();
  bool _emailFocused = false;

  // Story state
  int _storyIndex = 0;
  bool _showAuth = true;
  Timer? _storyTimer;

  @override
  void initState() {
    super.initState();
    _emailFocusNode.addListener(() {
      setState(() {
        _emailFocused = _emailFocusNode.hasFocus;
      });
    });
    if (widget.skipStory) {
      _storyIndex = 4;
      _showAuth = true;
    } else {
      _startStory();
    }
  }

  void _startStory() {
    _storyTimer = Timer.periodic(const Duration(milliseconds: 3800), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_storyIndex < 4) {
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
    _emailFocusNode.dispose();
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
      await AppSession.instance.setIdentity(
        method: identity.method,
        email: identity.email,
      );

      if (!mounted) return;

      if (wasAuthenticated) {
        context.go('/');
        return;
      }
      if (returningUser) {
        context.go('/');
        return;
      }

      // New user: check for a remote backup before proceeding to setup.
      bool hasBackup = false;
      try {
        hasBackup = await ref.read(backupServiceProvider).hasRemoteBackup();
      } catch (_) {}

      if (!mounted) return;
      if (hasBackup) {
        context.push('/onboarding/restore');
      } else {
        context.go('/onboarding/setup');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('تعذر تسجيل الدخول الآن. حاول مرة أخرى.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildAvatar(Color color, IconData icon) {
    return Align(
      widthFactor: 0.7,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black, width: 3)),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.read(authServiceProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final cardBg = isDark
        ? Colors.black.withValues(alpha: 0.4)
        : Colors.white.withValues(alpha: 0.65);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.08);
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.3)
        : Colors.black.withValues(alpha: 0.05);

    return Column(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 1200),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _buildStoryContent(isDark),
          ),
        ),
        if (_showAuth)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: cardBorder, width: 1.5),
              boxShadow: [
                BoxShadow(
                    color: shadowColor,
                    blurRadius: 30,
                    offset: const Offset(0, 10))
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
                      Text('المتابعة بالبريد الإلكتروني',
                          textAlign: TextAlign.center,
                          style: _alex(
                              18,
                              FontWeight.w800,
                              1.2,
                              Theme.of(context).brightness == Brightness.dark
                                  ? Colors.white
                                  : const Color(0xFF1A1A1A))),
                      const SizedBox(height: 24),
                      if (_busy)
                        const Center(
                            child: CircularProgressIndicator(color: _kGold))
                      else ...[
                        _buildEmailInput(auth),
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            Expanded(
                              child: Divider(
                                color: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Colors.white.withValues(alpha: 0.12)
                                    : Colors.black.withValues(alpha: 0.10),
                              ),
                            ),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                'أو',
                                style: _alex(
                                  12,
                                  FontWeight.w700,
                                  1.2,
                                  Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? Colors.white.withValues(alpha: 0.55)
                                      : Colors.black.withValues(alpha: 0.45),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Divider(
                                color: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Colors.white.withValues(alpha: 0.12)
                                    : Colors.black.withValues(alpha: 0.10),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          height: 54,
                          child: SignInWithAppleButton(
                            onPressed: () => _provider(auth.signInWithApple),
                            text: context.l10n.continueWithApple,
                            style:
                                Theme.of(context).brightness == Brightness.dark
                                    ? SignInWithAppleButtonStyle.white
                                    : SignInWithAppleButtonStyle.black,
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _providerButton(
                          iconWidget: const _GoogleMark(size: 20),
                          label: context.l10n.continueWithGoogle,
                          background:
                              Theme.of(context).brightness == Brightness.dark
                                  ? Colors.white
                                  : const Color(0xFFF3F4F6),
                          foreground:
                              Theme.of(context).brightness == Brightness.dark
                                  ? Colors.black
                                  : const Color(0xFF1A1A1A),
                          onTap: () => _provider(auth.signInWithGoogle),
                        ),
                      ]
                    ],
                  ),
                ),
              ),
            ),
          )
              .animate()
              .fade(duration: 800.ms)
              .slideY(begin: 0.2, end: 0, curve: Curves.easeOutBack),
      ],
    );
  }

  Widget _buildStoryContent(bool isDark) {
    if (_storyIndex == 0) {
      // Centered breathing/glowing logo splash
      return const Center(
        key: ValueKey(0),
        child: _LogoMark(isSplash: true),
      );
    } else if (_storyIndex == 1) {
      return const Column(
        key: ValueKey(1),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _LogoMark(isSplash: false),
          SizedBox(height: 24),
          _TypewriterText(
              text: 'قرش', size: 56, weight: FontWeight.w900, color: _kGold),
          SizedBox(height: 12),
          _TypewriterText(
              text: 'لنمو مالي ذكي وحياة أسهل.',
              size: 16,
              weight: FontWeight.w600),
        ],
      );
    } else if (_storyIndex == 2) {
      return const Column(
        key: ValueKey(2),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _TypewriterText(
              text: 'قرش تطبيق يساعدك تتحكم في مصروفاتك،',
              size: 16,
              weight: FontWeight.w500),
          SizedBox(height: 8),
          _TypewriterText(
              text: 'تخطط بذكاء، وتحقق أهدافك المالية',
              size: 16,
              weight: FontWeight.w500),
          SizedBox(height: 8),
          _TypewriterText(
              text: 'من خلال تقارير ذكية وتنبيهات لحظية،',
              size: 16,
              weight: FontWeight.w500),
          SizedBox(height: 8),
          _TypewriterText(
              text: 'وتجربة بسيطة صممت لك.', size: 16, weight: FontWeight.w500),
        ],
      );
    } else if (_storyIndex == 3) {
      return Column(
        key: const ValueKey(3),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _TypewriterText(
              text: 'نؤمن أن كل قرش له قيمة،',
              size: 16,
              weight: FontWeight.w500,
              color: _kGold),
          const SizedBox(height: 8),
          const _TypewriterText(
              text: 'ونحن هنا عشان نساعدك تستثمرها بحكمة.',
              size: 16,
              weight: FontWeight.w500,
              color: _kGold),
          const SizedBox(height: 48),
          const Icon(Icons.favorite_rounded, color: _kGold, size: 24)
              .animate()
              .scale(
                  delay: 1.seconds, duration: 500.ms, curve: Curves.elasticOut),
          const SizedBox(height: 16),
          _TypewriterText(
              text: 'من فريق قرش،',
              size: 14,
              weight: FontWeight.w500,
              color: isDark ? Colors.white70 : const Color(0xFF555555)),
          const SizedBox(height: 4),
          _TypewriterText(
              text: 'شكراً لأنك جزء من رحلتنا.',
              size: 14,
              weight: FontWeight.w500,
              color: isDark ? Colors.white70 : const Color(0xFF555555)),
        ],
      );
    } else {
      return Column(
        key: const ValueKey(4),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _TypewriterText(
              text: 'متحمسين نبدأ معك', size: 28, weight: FontWeight.w800),
          const SizedBox(height: 12),
          const _TypewriterText(
              text: 'لنكتب لك الخير ونساعدك تصنع فرقاً في حياتك.',
              size: 14,
              weight: FontWeight.w500,
              color: _kGold),
          const SizedBox(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildAvatar(const Color(0xFFC0C0C0), Icons.person),
              _buildAvatar(const Color(0xFF8B4513), Icons.person_3),
              _buildAvatar(const Color(0xFFDAA520), Icons.person_4),
            ],
          )
              .animate()
              .fade(delay: 1.seconds, duration: 800.ms)
              .slideY(begin: 0.5, end: 0),
          const SizedBox(height: 16),
          const _TypewriterText(
              text: 'انضم لمجتمع قرش وابدأ رحلتك المالية بثقة',
              size: 15,
              weight: FontWeight.w700),
        ],
      );
    }
  }

  Widget _buildEmailInput(AuthService auth) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A1A);

    final fieldBg = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.05);
    final fieldBorder = isDark
        ? Colors.white.withValues(alpha: 0.2)
        : Colors.black.withValues(alpha: 0.1);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: _emailFocused
                ? [
                    BoxShadow(
                      color: _kGold.withValues(alpha: 0.25),
                      blurRadius: 15,
                      spreadRadius: 2,
                    )
                  ]
                : [],
          ),
          child: TextField(
            focusNode: _emailFocusNode,
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            textDirection: TextDirection.ltr,
            style: _alex(15, FontWeight.w600, 1.4, textPrimary),
            decoration: InputDecoration(
              hintText: 'you@example.com',
              hintTextDirection: TextDirection.ltr,
              hintStyle: _alex(
                  14, FontWeight.w400, 1.4, textPrimary.withValues(alpha: 0.4)),
              prefixIcon: Icon(Icons.mail_outline_rounded,
                  color: textPrimary.withValues(alpha: 0.7)),
              filled: true,
              fillColor: fieldBg,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: fieldBorder)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: fieldBorder)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: _kGold, width: 1.5)),
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
                    const SnackBar(content: Text('تعذر إرسال الرمز.')));
              }
            } finally {
              if (mounted) setState(() => _busy = false);
            }
          },
        ),
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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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

// ── Phase 2: Goals Selection ───────────────────────────────────────────

class _GoalsPhase extends StatefulWidget {
  const _GoalsPhase({required this.onNext});
  final VoidCallback onNext;

  @override
  State<_GoalsPhase> createState() => _GoalsPhaseState();
}

class _GoalsPhaseState extends State<_GoalsPhase> {
  final Set<String> _selectedGoals = {};

  final List<Map<String, String>> _goals = [
    {
      'id': 'track',
      'title': 'تتبع المصروفات اليومية بدقة',
      'icon': '📊',
    },
    {
      'id': 'budget',
      'title': 'التخطيط لبناء ميزانية ذكية',
      'icon': '💰',
    },
    {
      'id': 'subscriptions',
      'title': 'إدارة وتقليل الاشتراكات',
      'icon': '💳',
    },
    {
      'id': 'saving',
      'title': 'تحقيق أهداف ادخارية محددة',
      'icon': '🎯',
    },
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A1A);

    final cardBg = isDark
        ? Colors.black.withValues(alpha: 0.4)
        : Colors.white.withValues(alpha: 0.65);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.08);
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.3)
        : Colors.black.withValues(alpha: 0.05);

    return Column(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _TypewriterText(
                  text: 'ما هي أهدافك المالية؟',
                  size: 24,
                  weight: FontWeight.w800),
              const SizedBox(height: 12),
              _TypewriterText(
                  text: 'اختر أهدافك لنقوم بتخصيص تجربتك في قرش.',
                  size: 14,
                  weight: FontWeight.w500,
                  color: isDark ? Colors.white70 : const Color(0xFF555555)),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: cardBorder, width: 1.5),
            boxShadow: [
              BoxShadow(
                  color: shadowColor,
                  blurRadius: 30,
                  offset: const Offset(0, 10))
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
                    ..._goals.map((goal) {
                      final isSelected = _selectedGoals.contains(goal['id']);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: InkWell(
                          onTap: () {
                            HapticFeedback.lightImpact();
                            setState(() {
                              if (isSelected) {
                                _selectedGoals.remove(goal['id']);
                              } else {
                                _selectedGoals.add(goal['id']!);
                              }
                            });
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? _kGold.withValues(alpha: 0.15)
                                  : textPrimary.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                  color: isSelected ? _kGold : cardBorder,
                                  width: 1.5),
                            ),
                            child: Row(
                              children: [
                                Text(goal['icon']!,
                                    style: const TextStyle(fontSize: 22)),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Text(goal['title']!,
                                      style: _alex(14, FontWeight.w700, 1.2,
                                          textPrimary)),
                                ),
                                if (isSelected)
                                  const Icon(Icons.check_circle_rounded,
                                      color: _kGold, size: 20)
                                else
                                  Icon(Icons.circle_outlined,
                                      color: textPrimary.withValues(alpha: 0.2),
                                      size: 20),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: 12),
                    AppPrimaryButton(
                      label: 'التالي',
                      onTap: () {
                        HapticFeedback.mediumImpact();
                        widget.onNext();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
            .animate()
            .fade(duration: 800.ms)
            .slideY(begin: 0.2, end: 0, curve: Curves.easeOutBack),
      ],
    );
  }
}

// ── Phase 3: Biometrics Protection ─────────────────────────────────────

class _BiometricsPhase extends StatefulWidget {
  const _BiometricsPhase({required this.onNext});
  final VoidCallback onNext;

  @override
  State<_BiometricsPhase> createState() => _BiometricsPhaseState();
}

class _BiometricsPhaseState extends State<_BiometricsPhase> {
  bool _loading = false;

  Future<void> _enableBiometrics() async {
    setState(() => _loading = true);
    try {
      final success = await AppLockService.instance.setEnabled(true);
      if (success) {
        await HapticFeedback.heavyImpact();
      }
    } catch (_) {}
    setState(() => _loading = false);
    widget.onNext();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A1A);

    final cardBg = isDark
        ? Colors.black.withValues(alpha: 0.4)
        : Colors.white.withValues(alpha: 0.65);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.08);
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.3)
        : Colors.black.withValues(alpha: 0.05);

    return Column(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: _kGold.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _kGold.withValues(alpha: 0.2),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(Icons.fingerprint_rounded,
                    color: _kGold, size: 60),
              )
                  .animate(
                      onPlay: (controller) => controller.repeat(reverse: true))
                  .scale(
                      end: const Offset(1.08, 1.08),
                      duration: 1500.ms,
                      curve: Curves.easeInOut)
                  .boxShadow(
                      end: BoxShadow(
                          color: _kGold.withValues(alpha: 0.3),
                          blurRadius: 30,
                          spreadRadius: 5),
                      duration: 1500.ms),
              const SizedBox(height: 32),
              const _TypewriterText(
                  text: 'أمان بياناتك المالية أولاً',
                  size: 24,
                  weight: FontWeight.w800),
              const SizedBox(height: 12),
              _TypewriterText(
                  text:
                      'قم بتفعيل الحماية بالبصمة للوصول السريع والآمن لمصروفاتك.',
                  size: 14,
                  weight: FontWeight.w500,
                  color: isDark ? Colors.white70 : const Color(0xFF555555)),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: cardBorder, width: 1.5),
            boxShadow: [
              BoxShadow(
                  color: shadowColor,
                  blurRadius: 30,
                  offset: const Offset(0, 10))
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
                    AppPrimaryButton(
                      label: 'تفعيل الحماية بالبصمة',
                      loading: _loading,
                      onTap: _enableBiometrics,
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        widget.onNext();
                      },
                      child: Text('تخطي الآن',
                          style: _alex(14, FontWeight.w600, 1.2,
                              textPrimary.withValues(alpha: 0.5))),
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
            .animate()
            .fade(duration: 800.ms)
            .slideY(begin: 0.2, end: 0, curve: Curves.easeOutBack),
      ],
    );
  }
}

// ── Phase 4: Smart Notifications ───────────────────────────────────────

class _NotificationsPhase extends StatefulWidget {
  const _NotificationsPhase({required this.onNext});
  final VoidCallback onNext;

  @override
  State<_NotificationsPhase> createState() => _NotificationsPhaseState();
}

class _NotificationsPhaseState extends State<_NotificationsPhase> {
  bool _loading = false;

  Future<void> _enableNotifications() async {
    setState(() => _loading = true);
    try {
      await LocalNotificationService.instance.requestPermissionsIfNeeded();
      await HapticFeedback.heavyImpact();
    } catch (_) {}
    setState(() => _loading = false);
    widget.onNext();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A1A);

    final cardBg = isDark
        ? Colors.black.withValues(alpha: 0.4)
        : Colors.white.withValues(alpha: 0.65);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.08);
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.3)
        : Colors.black.withValues(alpha: 0.05);

    return Column(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 300,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: cardBorder),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(
                          color: _kGold, shape: BoxShape.circle),
                      child: const Icon(Icons.notifications_active_rounded,
                          color: Colors.black, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('قرش • تنبيه الاشتراكات',
                              style: _alex(12, FontWeight.w800, 1.2, _kGold)),
                          const SizedBox(height: 4),
                          Text('سيتم تجديد اشتراك Netflix غداً (50 ر.س)',
                              style:
                                  _alex(11, FontWeight.w600, 1.2, textPrimary)),
                        ],
                      ),
                    ),
                  ],
                ),
              )
                  .animate(
                      onPlay: (controller) => controller.repeat(reverse: true))
                  .slideY(
                      begin: -0.2,
                      end: 0.05,
                      duration: 2.seconds,
                      curve: Curves.easeInOut)
                  .fade(begin: 0.7, end: 1.0, duration: 2.seconds),
              const SizedBox(height: 32),
              const _TypewriterText(
                  text: 'لا تفوت أي تنبيه مهم',
                  size: 24,
                  weight: FontWeight.w800),
              const SizedBox(height: 12),
              _TypewriterText(
                  text:
                      'احصل على تنبيهات فورية لمواعيد تجديد الاشتراكات وتجاوز الميزانيات.',
                  size: 14,
                  weight: FontWeight.w500,
                  color: isDark ? Colors.white70 : const Color(0xFF555555)),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: cardBorder, width: 1.5),
            boxShadow: [
              BoxShadow(
                  color: shadowColor,
                  blurRadius: 30,
                  offset: const Offset(0, 10))
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
                    AppPrimaryButton(
                      label: 'تفعيل التنبيهات الذكية',
                      loading: _loading,
                      onTap: _enableNotifications,
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        widget.onNext();
                      },
                      child: Text('تخطي الآن',
                          style: _alex(13, FontWeight.w700, 1.2,
                              textPrimary.withValues(alpha: 0.5))),
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
            .animate()
            .fade(duration: 800.ms)
            .slideY(begin: 0.2, end: 0, curve: Curves.easeOutBack),
      ],
    );
  }
}

// ── Phase 5: Language Selection ───────────────────────────────────────────────

class _LanguageSelectionPhase extends ConsumerStatefulWidget {
  const _LanguageSelectionPhase({required this.onNext});
  final VoidCallback onNext;

  @override
  ConsumerState<_LanguageSelectionPhase> createState() =>
      _LanguageSelectionPhaseState();
}

class _LanguageSelectionPhaseState
    extends ConsumerState<_LanguageSelectionPhase> {
  String _selected = 'ar';

  Future<void> _continue() async {
    await ref.read(saveLanguageUseCaseProvider).call(_selected);
    refreshUserSettings(ref);
    widget.onNext();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final cardBg = isDark
        ? Colors.black.withValues(alpha: 0.4)
        : Colors.white.withValues(alpha: 0.65);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.08);
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.3)
        : Colors.black.withValues(alpha: 0.05);

    return Column(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _TypewriterText(
                  text: 'اختر لغتك المفضلة', size: 24, weight: FontWeight.w800),
              const SizedBox(height: 12),
              _TypewriterText(
                  text: 'يمكنك تغيير اللغة من الإعدادات في أي وقت',
                  size: 14,
                  weight: FontWeight.w500,
                  color: isDark ? Colors.white70 : const Color(0xFF555555)),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: cardBorder, width: 1.5),
            boxShadow: [
              BoxShadow(
                  color: shadowColor,
                  blurRadius: 30,
                  offset: const Offset(0, 10))
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
                    _LangCard(
                        title: 'العربية',
                        tag: 'RTL',
                        selected: _selected == 'ar',
                        onTap: () => setState(() => _selected = 'ar')),
                    const SizedBox(height: 16),
                    _LangCard(
                        title: 'English',
                        tag: 'LTR',
                        selected: _selected == 'en',
                        onTap: () => setState(() => _selected = 'en')),
                    const SizedBox(height: 24),
                    AppPrimaryButton(label: 'التالي', onTap: _continue),
                  ],
                ),
              ),
            ),
          ),
        )
            .animate()
            .fade(duration: 800.ms)
            .slideY(begin: 0.2, end: 0, curve: Curves.easeOutBack),
      ],
    );
  }
}

class _LangCard extends StatelessWidget {
  const _LangCard(
      {required this.title,
      required this.tag,
      required this.selected,
      required this.onTap});
  final String title;
  final String tag;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A1A);

    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.08);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? _kGold.withValues(alpha: 0.15)
              : textPrimary.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? _kGold : cardBorder, width: 1.5),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: _alex(18, FontWeight.w800, 1.2, textPrimary)),
                  const SizedBox(height: 4),
                  Text(tag,
                      style: _alex(12, FontWeight.w600, 1.2,
                          textPrimary.withValues(alpha: 0.5))),
                ],
              ),
            ),
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? _kGold : Colors.transparent,
                border: Border.all(
                    color:
                        selected ? _kGold : textPrimary.withValues(alpha: 0.2),
                    width: 1.5),
              ),
              child: selected
                  ? const Icon(Icons.check_rounded,
                      size: 16, color: Colors.black)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Phase 6: Country Selection ────────────────────────────────────────────────

class _CountrySelectionPhase extends ConsumerStatefulWidget {
  const _CountrySelectionPhase({required this.onNext});
  final VoidCallback onNext;

  @override
  ConsumerState<_CountrySelectionPhase> createState() =>
      _CountrySelectionPhaseState();
}

class _CountrySelectionPhaseState
    extends ConsumerState<_CountrySelectionPhase> {
  void _continue(
    _CountryOption? selectedOption,
    OnboardingCountry? selectedCountry,
  ) {
    if (selectedOption == null) return;
    if (selectedCountry == null ||
        selectedCountry.code.toLowerCase() !=
            selectedOption.code.toLowerCase()) {
      ref.read(onboardingSelectionProvider.notifier).state =
          selectedOption.toSelection();
    }
    widget.onNext();
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
            final selected = ref.read(onboardingSelectionProvider);
            final options = _countryOptions(
              ref.read(supportedCountriesProvider).valueOrNull ??
                  const <RemoteCountry>[],
              ref.read(activeCurrenciesProvider).valueOrNull ??
                  const <RemoteCurrency>[],
            );
            final normalizedSearch = searchQuery.trim().toLowerCase();
            final filteredCountries = options
                .where((country) =>
                    country.nameAr.contains(searchQuery) ||
                    country.nameEn.toLowerCase().contains(normalizedSearch) ||
                    country.currencyNameAr.contains(searchQuery) ||
                    country.currencyNameEn
                        .toLowerCase()
                        .contains(normalizedSearch) ||
                    country.currencyCode
                        .toLowerCase()
                        .contains(normalizedSearch))
                .toList();

            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                height: MediaQuery.of(context).size.height * 0.7,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(32)),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.1)),
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4))),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TextField(
                        onChanged: (v) => setModalState(() => searchQuery = v),
                        style: _alex(14, FontWeight.w600, 1.2, Colors.white),
                        decoration: InputDecoration(
                          hintText: 'ابحث عن بلدك أو عملتك...',
                          hintStyle: _alex(14, FontWeight.w500, 1.2,
                              Colors.white.withValues(alpha: 0.5)),
                          prefixIcon: Icon(Icons.search_rounded,
                              color: Colors.white.withValues(alpha: 0.5)),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.1),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide.none),
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
                          final isSelected = selected != null &&
                              option.code.toLowerCase() ==
                                  selected.code.toLowerCase();
                          return _CountryTile(
                            option: option,
                            selected: isSelected,
                            onTap: () {
                              ref
                                  .read(onboardingSelectionProvider.notifier)
                                  .state = option.toSelection();
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark
        ? Colors.black.withValues(alpha: 0.4)
        : Colors.white.withValues(alpha: 0.65);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.08);
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.3)
        : Colors.black.withValues(alpha: 0.05);

    final options = _countryOptions(
      ref.watch(supportedCountriesProvider).valueOrNull ??
          const <RemoteCountry>[],
      ref.watch(activeCurrenciesProvider).valueOrNull ??
          const <RemoteCurrency>[],
    );
    final selectedCountry = ref.watch(onboardingSelectionProvider);
    final selectedOption = _selectedOption(options, selectedCountry);

    return Column(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _TypewriterText(
                  text: 'اختر بلدك وعملتك', size: 24, weight: FontWeight.w800),
              const SizedBox(height: 12),
              _TypewriterText(
                  text: 'إعدادات سريعة لتخصيص تجربتك\nحسب منطقتك.',
                  size: 14,
                  weight: FontWeight.w500,
                  color: isDark ? Colors.white70 : const Color(0xFF555555)),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: cardBorder, width: 1.5),
            boxShadow: [
              BoxShadow(
                  color: shadowColor,
                  blurRadius: 30,
                  offset: const Offset(0, 10))
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
                    Text('العملة',
                        style: _alex(13, FontWeight.w700, 1.2, _kGold)),
                    const SizedBox(height: 8),
                    _DropdownField(
                      leading: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                            color: _kGold.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.payments_outlined,
                            size: 18, color: _kGold),
                      ),
                      label: selectedOption == null
                          ? 'تحميل...'
                          : '${selectedOption.localizedCurrency(context)} (${selectedOption.currencyCode})',
                      onTap: options.isEmpty
                          ? () {}
                          : () => _showCountryPicker(context),
                    ),
                    const SizedBox(height: 24),
                    AppPrimaryButton(
                      label: 'التالي',
                      disabled: selectedOption == null,
                      onTap: () => _continue(selectedOption, selectedCountry),
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
            .animate()
            .fade(duration: 800.ms)
            .slideY(begin: 0.2, end: 0, curve: Curves.easeOutBack),
      ],
    );
  }

  List<_CountryOption> _countryOptions(
      List<RemoteCountry> countries, List<RemoteCurrency> currencies) {
    final options = [
      for (final country in countries)
        if (_preferredCurrency(country, currencies) != null)
          _CountryOption(
              country: country,
              currency: _preferredCurrency(country, currencies)!),
    ];
    options.sort((a, b) {
      if (a.code == 'sa') return -1;
      if (b.code == 'sa') return 1;
      return a.localizedSortKey.compareTo(b.localizedSortKey);
    });
    return options;
  }

  RemoteCurrency? _preferredCurrency(
      RemoteCountry country, List<RemoteCurrency> currencies) {
    final code = country.code.trim().toUpperCase();
    for (final currency in currencies) {
      if (currency.countryCodes.contains(code)) return currency;
    }
    return null;
  }

  _CountryOption? _selectedOption(
      List<_CountryOption> options, OnboardingCountry? selected) {
    if (selected == null) return options.isEmpty ? null : options.first;
    for (final option in options) {
      if (option.code.toLowerCase() == selected.code.toLowerCase()) {
        return option;
      }
    }
    return options.isEmpty ? null : options.first;
  }
}

// ── Phase 7: Date of birth ───────────────────────────────────────────────────

class _DateOfBirthPhase extends ConsumerWidget {
  const _DateOfBirthPhase({required this.onNext});
  final VoidCallback onNext;

  Future<void> _pickDate(BuildContext context, WidgetRef ref) async {
    final now = DateTime.now();
    final lastDate = DateTime(now.year - 13, now.month, now.day);
    final firstDate = DateTime(now.year - 100, now.month, now.day);
    final current = ref.read(onboardingDateOfBirthProvider);
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime(now.year - 25, now.month, now.day),
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: 'اختر تاريخ الميلاد',
      cancelText: 'إلغاء',
      confirmText: 'تم',
    );
    if (picked != null) {
      ref.read(onboardingDateOfBirthProvider.notifier).state =
          DateTime.utc(picked.year, picked.month, picked.day);
    }
  }

  String _format(DateTime date) {
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(onboardingDateOfBirthProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark
        ? Colors.black.withValues(alpha: 0.4)
        : Colors.white.withValues(alpha: 0.65);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.08);
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.3)
        : Colors.black.withValues(alpha: 0.05);

    return Column(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _TypewriterText(
                text: 'تاريخ الميلاد',
                size: 24,
                weight: FontWeight.w800,
              ),
              const SizedBox(height: 12),
              _TypewriterText(
                text: 'نستخدمه لتخصيص تجربة قرش\nبدون عرضه داخل التطبيق.',
                size: 14,
                weight: FontWeight.w500,
                color: isDark ? Colors.white70 : const Color(0xFF555555),
              ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: cardBorder, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: shadowColor,
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
                      'تاريخ الميلاد',
                      style: _alex(13, FontWeight.w700, 1.2, _kGold),
                    ),
                    const SizedBox(height: 8),
                    _DropdownField(
                      leading: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: _kGold.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.cake_outlined,
                          size: 18,
                          color: _kGold,
                        ),
                      ),
                      label:
                          selected == null ? 'اختر التاريخ' : _format(selected),
                      onTap: () => _pickDate(context, ref),
                    ),
                    const SizedBox(height: 24),
                    AppPrimaryButton(
                      label: 'التالي',
                      disabled: selected == null,
                      onTap: selected == null ? null : onNext,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ).animate().fade(duration: 800.ms).slideY(
              begin: 0.2,
              end: 0,
              curve: Curves.easeOutBack,
            ),
      ],
    );
  }
}

// ── Phase 7: iOS Shortcut Instructions ─────────────────────────────────

class _IosShortcutPhase extends ConsumerWidget {
  const _IosShortcutPhase({required this.onNext});
  final VoidCallback onNext;

  static List<_IosStep> _getSteps(BuildContext context, String currencyCode) {
    final locale = Localizations.localeOf(context).languageCode;
    if (locale == 'en') {
      return [
        const _IosStep(
            'Delete Old',
            'Open Shortcuts app -> Automation. Delete any old Qirsh automation.',
            Icons.delete_outline_rounded),
        const _IosStep('New (+)', 'Press + and scroll down to "Message".',
            Icons.add_circle_outline_rounded),
        _IosStep(
            'Filter Messages',
            'Press "Message Contents" and type "$currencyCode".',
            Icons.filter_alt_outlined),
        const _IosStep('Run Immediately',
            'Enable "Run Immediately" and press Next.', Icons.bolt_rounded),
        const _IosStep('Blank Automation', 'Press "New Blank Automation".',
            Icons.insert_drive_file_outlined),
        const _IosStep(
            'Send to App',
            'Search for "Process Bank SMS". Choose "Shortcut Input" for SMS Text.',
            Icons.send_rounded),
        const _IosStep(
            'Final Shape',
            'Receive messages as input -> Process Bank SMS.',
            Icons.volume_off_rounded),
        const _IosStep('Save', 'Press Save in the top right to complete.',
            Icons.check_circle_outline_rounded),
      ];
    }
    return [
      const _IosStep(
          'احذف القديم',
          'افتح تطبيق Shortcuts وروح لتبويب Automation. لو فيه Automation قديم للتطبيق، احذفه.',
          Icons.delete_outline_rounded),
      const _IosStep(
          'جديد (+)',
          'اضغط New Automation (+) ومرّر للأسفل حتى تلقى «Message».',
          Icons.add_circle_outline_rounded),
      _IosStep(
          'حدّد الرسائل',
          'اضغط على «Message Contents» واكتب رمز العملة مثل $currencyCode.',
          Icons.filter_alt_outlined),
      const _IosStep('بدون تأكيد', 'فعّل «Run Immediately» واضغط Next.',
          Icons.bolt_rounded),
      const _IosStep('اختصار فارغ', 'اضغط «New Blank Automation».',
          Icons.insert_drive_file_outlined),
      const _IosStep(
          'إرسال للتطبيق',
          'ابحث عن «Process Bank SMS». في SMS Text اختَر «Shortcut Input».',
          Icons.send_rounded),
      const _IosStep(
          'الشكل النهائي',
          'لازم يظهر: Receive messages as input ثم Process Bank SMS.',
          Icons.volume_off_rounded),
      const _IosStep('حفظ', 'اضغط زر الحفظ في الأعلى وتم الإعداد.',
          Icons.check_circle_outline_rounded),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A1A);

    final cardBg = isDark
        ? Colors.black.withValues(alpha: 0.4)
        : Colors.white.withValues(alpha: 0.65);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.08);

    final currencyCode =
        ref.read(onboardingSelectionProvider)?.currencyCode ?? 'SAR';
    final steps = _getSteps(context, currencyCode);

    return Column(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.apple_rounded, color: textPrimary, size: 40),
              const SizedBox(height: 8),
              const _TypewriterText(
                  text: 'إعداد اختصار iOS', size: 22, weight: FontWeight.w800),
              const SizedBox(height: 6),
              _TypewriterText(
                  text: 'اتبع الخطوات لتفعيل تمرير الرسائل تلقائياً.',
                  size: 13,
                  weight: FontWeight.w500,
                  color: isDark ? Colors.white70 : const Color(0xFF555555)),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          height: MediaQuery.of(context).size.height * 0.55,
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: cardBorder, width: 1.5),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Expanded(
                      child: ListView.separated(
                        itemCount: steps.length,
                        separatorBuilder: (context, index) => Container(
                          height: 12,
                          margin: const EdgeInsets.only(right: 14),
                          width: 1.5,
                          color: Colors.white.withValues(alpha: 0.1),
                          alignment: Alignment.centerRight,
                        ),
                        itemBuilder: (context, index) {
                          final step = steps[index];
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                decoration: const BoxDecoration(
                                    color: _kGold, shape: BoxShape.circle),
                                alignment: Alignment.center,
                                child: Text('${index + 1}',
                                    style: _alex(11, FontWeight.w800, 1.0,
                                        Colors.black)),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(step.title,
                                            style: _alex(13, FontWeight.w800,
                                                1.2, textPrimary)),
                                        const SizedBox(width: 6),
                                        Icon(step.icon,
                                            color: textPrimary.withValues(
                                                alpha: 0.6),
                                            size: 13),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(step.body,
                                        style: _alex(
                                            11,
                                            FontWeight.w500,
                                            1.4,
                                            isDark
                                                ? Colors.white70
                                                : const Color(0xFF555555))),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    AppPrimaryButton(
                      label: 'التالي (بدء التحقق)',
                      onTap: () {
                        HapticFeedback.mediumImpact();
                        onNext();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
            .animate()
            .fade(duration: 800.ms)
            .slideY(begin: 0.2, end: 0, curve: Curves.easeOutBack),
      ],
    );
  }
}

class _IosStep {
  const _IosStep(this.title, this.body, this.icon);
  final String title;
  final String body;
  final IconData icon;
}

class _TypewriterText extends StatefulWidget {
  const _TypewriterText(
      {required this.text,
      required this.size,
      required this.weight,
      this.color});
  final String text;
  final double size;
  final FontWeight weight;
  final Color? color;

  @override
  State<_TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<_TypewriterText> {
  int _chars = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_chars < widget.text.length) {
        setState(() {
          _chars++;
          if (_chars % 4 == 0) {
            HapticFeedback.selectionClick();
          }
        });
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fallbackColor = isDark ? Colors.white : const Color(0xFF1A1A1A);
    return Text(
      display,
      textAlign: TextAlign.center,
      style:
          _alex(widget.size, widget.weight, 1.4, widget.color ?? fallbackColor),
    );
  }
}

class _LogoMark extends StatelessWidget {
  const _LogoMark({this.isSplash = false});
  final bool isSplash;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final coinPath = isDark ? AppAssets.qirshCoinGold : AppAssets.qirshCoin;

    if (isSplash) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(coinPath, width: 90, height: 90),
          const SizedBox(height: 16),
          Text(
            'قرش',
            style: _alex(48, FontWeight.w900, 1.2, isDark ? Colors.white : const Color(0xFF1A1A1A)),
          ),
        ],
      ).animate(onPlay: (controller) => controller.repeat(reverse: true)).scale(
          begin: const Offset(0.96, 0.96),
          end: const Offset(1.04, 1.04),
          duration: 2000.ms,
          curve: Curves.easeInOut);
    }

    return SizedBox(
      width: 70,
      height: 70,
      child: Image.asset(coinPath),
    ).animate().scale(duration: 800.ms, curve: Curves.elasticOut);
  }
}
// ── Data models ───────────────────────────────────────────────────────────────

class _CountryOption {
  const _CountryOption({required this.country, required this.currency});

  final RemoteCountry country;
  final RemoteCurrency currency;

  String get code => country.code.toLowerCase();
  String get flagEmoji => country.flagEmoji;
  String get currencyCode => currency.code.toUpperCase();
  String get nameAr => country.nameAr;
  String get nameEn => country.nameEn;
  String get currencyNameAr => currency.nameAr;
  String get currencyNameEn => currency.nameEn;
  String get localizedSortKey => nameAr.isNotEmpty ? nameAr : nameEn;

  String localizedName(BuildContext context) {
    return Localizations.localeOf(context).languageCode == 'en'
        ? country.nameEn
        : country.nameAr;
  }

  String localizedCurrency(BuildContext context) {
    return Localizations.localeOf(context).languageCode == 'en'
        ? currency.nameEn
        : currency.nameAr;
  }

  OnboardingCountry toSelection() {
    return OnboardingCountry(
      code: code,
      name: country.nameAr,
      currency: currency.nameAr,
      currencyCode: currencyCode,
    );
  }
}

// ── Shared UI widgets ─────────────────────────────────────────────────────────

class _FlagAvatar extends StatelessWidget {
  const _FlagAvatar({required this.code, this.emoji, this.size = 30});
  final String code;
  final String? emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A1A);

    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.08),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE5E7EB),
        shape: BoxShape.circle,
        border: Border.all(color: textPrimary.withValues(alpha: 0.15)),
      ),
      child: Center(
        child: Text(
          emoji == null || emoji!.isEmpty ? code.toUpperCase() : emoji!,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize:
                emoji == null || emoji!.isEmpty ? size * 0.32 : size * 0.54,
            fontWeight: FontWeight.w800,
            height: 1,
            color: textPrimary,
          ),
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

  final _CountryOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? _kGold.withValues(alpha: 0.10)
              : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? _kGold.withValues(alpha: 0.45)
                : const Color(0xFF2A2A2A),
          ),
        ),
        child: Row(
          children: [
            _FlagAvatar(code: option.code, emoji: option.flagEmoji, size: 34),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(option.localizedName(context),
                      style: _alex(12, FontWeight.w800, 1.2, Colors.white)),
                  const SizedBox(height: 4),
                  Text(option.localizedCurrency(context),
                      style: _alex(10, FontWeight.w700, 1.2,
                          Colors.white.withValues(alpha: 0.45))),
                ],
              ),
            ),
            Text(
              option.currencyCode,
              style: _alex(
                11,
                FontWeight.w800,
                1.2,
                selected ? _kGold : Colors.white.withValues(alpha: 0.35),
                tabular: true,
              ),
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

class _DropdownField extends StatelessWidget {
  const _DropdownField({
    required this.leading,
    required this.label,
    required this.onTap,
  });

  final Widget leading;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A1A);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: textPrimary.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: textPrimary.withValues(alpha: 0.1)),
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 14),
            Expanded(
              child: Text(label,
                  style: _alex(15, FontWeight.w700, 1.2, textPrimary)),
            ),
            Icon(Icons.keyboard_arrow_down_rounded,
                color: textPrimary.withValues(alpha: 0.4), size: 22),
          ],
        ),
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
