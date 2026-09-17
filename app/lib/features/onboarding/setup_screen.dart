import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../l10n/app_localizations.dart';
import '../capture/services/local_notification_service.dart';
import 'onboarding_options.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/theme/app_colors.dart';
import '../common/repo_error_messages.dart';

/// Same flat navy the native launch screen uses (`flutter_native_splash.yaml`,
/// `color: "#021B79"`) and the rest of the pre-dashboard onboarding sequence.
const _setupBlue = AppBrandBlue.brand;
const _setupAccent = AppBrandBlue.pale;

/// Page 4 of the redesigned onboarding: one activation step at a time.
///
/// Steps, in order:
///   0. Country / currency   → saves the base currency (required for accounts)
///   1. Notifications        → OS permission prompt
///   2. Shortcut install     → instructions carousel, self-declared
///
/// Cloud and AI processing default to enabled for new installs and are synced
/// to iOS on app startup, but they are the USER's revocable choice (MALI-001):
/// the toggles live in الإعدادات ← الأمان والخصوصية and every capture/sync/AI
/// path honors the stored value.
///
/// Completing a step auto-advances to the next one. The final "ابدأ" finishes
/// onboarding and enters the app once all three are done.
enum OnboardingSetupEntry { full, captureGuide }

class OnboardingSetupScreen extends ConsumerStatefulWidget {
  const OnboardingSetupScreen({
    super.key,
    this.entry = OnboardingSetupEntry.full,
  });

  final OnboardingSetupEntry entry;

  @override
  ConsumerState<OnboardingSetupScreen> createState() =>
      _OnboardingSetupScreenState();
}

class _CountryChoice {
  _CountryChoice(this.code, this.flag, this.name, this.currency);
  final String code;
  final String flag;
  final String name;
  final String currency;
}

/// Country names come from the ARB, so the list is built per-locale rather
/// than being a `const` frozen at class-load.
///
/// Resolving by code keeps the SELECTION stable while the LABEL follows the
/// language.
List<_CountryChoice> _countriesIn(BuildContext context) => <_CountryChoice>[
  _CountryChoice('SA', '🇸🇦', context.l10n.countrySA, 'SAR'),
  _CountryChoice('AE', '🇦🇪', context.l10n.countryAE, 'AED'),
  _CountryChoice('EG', '🇪🇬', context.l10n.countryEG, 'EGP'),
  _CountryChoice('KW', '🇰🇼', context.l10n.countryKW, 'KWD'),
  _CountryChoice('QA', '🇶🇦', context.l10n.countryQA, 'QAR'),
  _CountryChoice('BH', '🇧🇭', context.l10n.countryBH, 'BHD'),
  _CountryChoice('OM', '🇴🇲', context.l10n.countryOM, 'OMR'),
      _CountryChoice('JO', '🇯🇴', context.l10n.countryJO, 'JOD'),
    ];

class _OnboardingSetupScreenState extends ConsumerState<OnboardingSetupScreen> {
  static const _stepCount = 3;

  final _done = List<bool>.filled(_stepCount, false);
  // The CODE is state; the label is not. Storing a `_CountryChoice` meant
  // holding a localized name in state, which would keep whichever language was
  // active when the screen was first built.
  String _countryCode = 'SA';
  _CountryChoice _selectedCountry(BuildContext context) =>
      _countriesIn(context).firstWhere((c) => c.code == _countryCode,
          orElse: () => _countriesIn(context).first);

  bool _busy = false;
  int _currentStep = 0;

  @override
  void initState() {
    super.initState();
    if (widget.entry == OnboardingSetupEntry.captureGuide) {
      _done
        ..[0] = true
        ..[1] = true;
      _currentStep = 2;
      unawaited(_loadRestoredCurrency());
    }
  }

  Future<void> _loadRestoredCurrency() async {
    final settings =
        await ref.read(userSettingsRepositoryProvider).getSettings();
    if (!mounted) return;
    final currency = settings.currency.trim().toUpperCase();
    final match = _countriesIn(context).where((item) => item.currency == currency);
    if (match.isNotEmpty) {
      setState(() => _countryCode = match.first.code);
    }
  }

  bool get _canFinish => _done.every((done) => done);
  int get _completed => _done.where((d) => d).length;

  void _markDone(int step) {
    if (!mounted) return;
    HapticFeedback.lightImpact();
    setState(() => _done[step] = true);
    if (step == _currentStep && step < _stepCount - 1) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (!mounted || _currentStep != step) return;
        setState(() => _currentStep = step + 1);
      });
    }
  }

  void _goBack() {
    if (_currentStep == 0) return;
    HapticFeedback.selectionClick();
    setState(() => _currentStep--);
  }

  // ── Step 0: country / currency ────────────────────────────────────────
  Future<void> _saveCountry(_CountryChoice choice) async {
    if (_busy) return;
    HapticFeedback.selectionClick();
    setState(() {
      _countryCode = choice.code;
      _busy = true;
    });
    try {
      ref.read(onboardingSelectionProvider.notifier).state = OnboardingCountry(
        code: choice.code,
        name: choice.name,
        currency: choice.currency,
        currencyCode: choice.currency,
      );
      await ref
          .read(saveCountryCurrencyUseCaseProvider)
          .call(choice.code, choice.currency);
      _markDone(0);
    } catch (error) {
      if (!mounted) return;
      final message = error is RepoException
          ? repoErrorMessage(context, error)
          : context.l10n.setupSaveFailed;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Step 1: notifications ─────────────────────────────────────────────
  Future<void> _enableNotifications() async {
    setState(() => _busy = true);
    try {
      await LocalNotificationService.instance.requestPermissionsIfNeeded();
      _markDone(1);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Finish ────────────────────────────────────────────────────────────
  Future<void> _finish() async {
    HapticFeedback.lightImpact();
    setState(() => _busy = true);
    try {
      await AppSession.instance.finishOnboarding();
      if (mounted) context.go('/');
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(context.l10n.setupFinishFailed)),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: _setupBlue,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: AppSpacing.s2),
            const ExcludeSemantics(
              child: Image(
                image: AssetImage(AppAssets.qirshLogoFull),
                height: 32,
              ),
            ),
            const SizedBox(height: AppSpacing.s2),
            _header(l10n),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.03),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                  key: ValueKey(_currentStep),
                  child: _stepPage(l10n, _currentStep),
                ),
              ),
            ),
            _finishBar(l10n),
          ],
        ),
      ),
    );
  }

  Widget _header(AppL10n l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, 12, AppSpacing.gutter, 8),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: _currentStep > 0
                ? IconButton(
                    padding: EdgeInsets.zero,
                    onPressed: _busy ? null : _goBack,
                    icon: const Icon(AppLucideIcons.arrowLeft,
                        size: 18, color: Colors.white70),
                  )
                : null,
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Row(
              children: [
                for (var i = 0; i < _stepCount; i++) ...[
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: SizedBox(
                        height: 4,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          color: _done[i] || i < _currentStep
                              ? _setupAccent
                              : Colors.white.withValues(alpha: 0.16),
                        ),
                      ),
                    ),
                  ),
                  if (i < _stepCount - 1) const SizedBox(width: 6),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.s3),
          Text(
            l10n.setupStepLabel(_currentStep + 1, _stepCount),
            style: AppTypography.caption(Colors.white.withValues(alpha: 0.56)),
          ),
        ],
      ),
    );
  }

  Widget _stepPage(AppL10n l10n, int step) {
    switch (step) {
      case 0:
        return _countryStep(l10n);
      case 1:
        return _actionStep(
          step: 1,
          icon: AppLucideIcons.bellRing,
          title: l10n.setupNotificationsTitle,
          body: l10n.setupNotificationsBody,
          cta: l10n.setupNotificationsCta,
          onTap: _enableNotifications,
        );
      default:
        return _shortcutStep(l10n);
    }
  }

  /// Shared hero layout for a single step: a glowing icon, a big centered
  /// title/body, then the step's own control underneath.
  Widget _stepHero({
    required int step,
    required IconData icon,
    required String title,
    required String body,
    required Widget control,
    Widget? eyebrow,
  }) {
    final done = _done[step];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.s6, AppSpacing.gutter, AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (eyebrow != null) ...[
            eyebrow,
            const SizedBox(height: AppSpacing.s7),
          ],
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _setupAccent.withValues(alpha: 0.12),
                boxShadow: [
                  BoxShadow(
                    color: _setupAccent.withValues(alpha: 0.28),
                    blurRadius: 44,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: done
                  ? const Icon(AppLucideIcons.check,
                          color: _setupAccent, size: 36)
                      .animate(key: ValueKey('done-icon-$step'))
                      .scale(curve: Curves.easeOutBack, duration: 400.ms)
                      .then()
                      .shimmer(duration: 600.ms, color: Colors.white)
                  : Icon(icon, color: _setupAccent, size: 36),
            ),
          ),
          const SizedBox(height: AppSpacing.s6),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppTypography.custom(
              size: 26,
              weight: FontWeight.w800,
              height: 1.22,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          Text(
            body,
            textAlign: TextAlign.center,
            style: AppTypography.body(Colors.white.withValues(alpha: 0.68))
                .copyWith(height: 1.55),
          ),
          const SizedBox(height: AppSpacing.s7),
          control,
        ],
      ),
    );
  }

  Widget _countryStep(AppL10n l10n) {
    return _stepHero(
      step: 0,
      icon: AppLucideIcons.globe,
      title: l10n.setupCountryTitle,
      body: l10n.setupCountryBody,
      eyebrow: Column(
        children: [
          Text(
            l10n.setupHeaderTitle,
            textAlign: TextAlign.center,
            style: AppTypography.custom(
              size: 20,
              weight: FontWeight.w700,
              height: 1.2,
              color: _setupAccent,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.setupHeaderSubtitle,
            textAlign: TextAlign.center,
            style: AppTypography.caption(Colors.white.withValues(alpha: 0.5)),
          ),
        ],
      ),
      // A pill this screen owns, rather than a themed ChoiceChip.
      //
      // The chips rendered as SOLID WHITE pills carrying WHITE labels —
      // measured on the capture, rgb(255,255,255) against an rgb(8,26,116)
      // page. A new user could read exactly one country, the one already
      // selected, in BOTH languages, on the mandatory first-run step.
      //
      // Three attempts failed to move it: per-chip `backgroundColor`, per-chip
      // `color` (the M3 state property), and an ancestor `ChipTheme`. Each of
      // them resolves correctly in a widget test — pumping the REAL screen and
      // reading the chips' `Ink` reports `white @ 10%` — and each still landed
      // white on the device. The `Ink` is not the whole story: the chip's own
      // `Material` falls back to the theme's canvas colour and paints it inside
      // the pill shape, underneath. On a screen that paints its own navy over a
      // LIGHT theme, that fallback is white, and no property on the chip
      // reaches it.
      //
      // So the pill is drawn here instead: a transparent Material, an explicit
      // decoration, and nothing left to inherit. Same shape, same spacing, same
      // selected treatment — and `country_chip_contrast_test` now measures the
      // composite rather than trusting a property.
      control: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final choice in _countriesIn(context))
            _CountryPill(
              choice: choice,
              selected: _countryCode == choice.code,
              onTap: _busy ? null : () => _saveCountry(choice),
            ),
        ],
      ),
    );
  }

  Widget _actionStep({
    required int step,
    required IconData icon,
    required String title,
    required String body,
    required String cta,
    required Future<void> Function() onTap,
  }) {
    return _stepHero(
      step: step,
      icon: icon,
      title: title,
      body: body,
      control: _done[step]
          ? const SizedBox.shrink()
          : SizedBox(
              width: double.infinity,
              height: AppSpacing.buttonHeight,
              child: FilledButton(
                onPressed: _busy ? null : () => onTap(),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: _setupBlue,
                ),
                child: Text(cta, style: AppTypography.bodyStrong(_setupBlue)),
              ),
            ),
    );
  }

  Widget _shortcutStep(AppL10n l10n) {
    const step = 2;
    final steps = <(String, String)>[
      (l10n.setupShortcutStep1Title, l10n.setupShortcutStep1Body),
      (l10n.setupShortcutStep2Title, l10n.setupShortcutStep2Body),
      (
        l10n.setupShortcutStep3Title,
        l10n.setupShortcutStep3Body(_selectedCountry(context).currency)
      ),
      (l10n.setupShortcutStep4Title, l10n.setupShortcutStep4Body),
      (l10n.setupShortcutStep5Title, l10n.setupShortcutStep5Body),
      (l10n.setupShortcutStep6Title, l10n.setupShortcutStep6Body),
    ];
    return _stepHero(
      step: step,
      icon: AppLucideIcons.share,
      title: l10n.setupShortcutTitle,
      body: l10n.setupShortcutBody,
      control: _done[step]
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 118,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: steps.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, i) {
                      final (title, body) = steps[i];
                      return Container(
                        width: 220,
                        padding: const EdgeInsets.all(AppSpacing.s3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${i + 1}. $title',
                                style: AppTypography.bodyStrong(Colors.white)),
                            const SizedBox(height: 6),
                            Expanded(
                              child: Text(body,
                                  style: AppTypography.caption(
                                      Colors.white.withValues(alpha: 0.6)),
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.s4),
                SizedBox(
                  width: double.infinity,
                  height: AppSpacing.buttonHeight,
                  child: FilledButton(
                    onPressed: _busy ? null : () => _markDone(step),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: _setupBlue,
                    ),
                    child: Text(l10n.setupShortcutCta,
                        style: AppTypography.bodyStrong(_setupBlue)),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _finishBar(AppL10n l10n) {
    final ready = _canFinish && !_busy;
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, 8, AppSpacing.gutter, 16),
      child: SizedBox(
        width: double.infinity,
        height: AppSpacing.buttonHeight,
        child: FilledButton(
          onPressed: ready ? _finish : null,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: _setupBlue,
            disabledBackgroundColor: Colors.white.withValues(alpha: 0.1),
          ),
          child: Text(l10n.setupFinishCta,
              style: AppTypography.bodyStrong(
                ready ? _setupBlue : Colors.white38,
              )),
        ),
      ).animate(target: _completed == _stepCount ? 1 : 0).scaleXY(
            begin: 1,
            end: 1.03,
            duration: 260.ms,
            curve: Curves.easeOutBack,
          ),
    );
  }
}

/// One country/currency choice on the setup step.
///
/// Deliberately not a `ChoiceChip`: see the note at its call site. Material's
/// chip paints its own surface from the ambient theme underneath anything the
/// widget sets, which on this navy screen meant a white pill under white text.
class _CountryPill extends StatelessWidget {
  const _CountryPill({
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  final _CountryChoice choice;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fill = selected
        ? _setupAccent.withValues(alpha: 0.22)
        : Colors.white.withValues(alpha: 0.10);
    final border = selected
        ? _setupAccent.withValues(alpha: 0.60)
        : Colors.white.withValues(alpha: 0.24);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        child: Ink(
          decoration: ShapeDecoration(
            color: fill,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.chip),
              side: BorderSide(color: border),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  const Icon(Icons.check, size: 16, color: Colors.white),
                  const SizedBox(width: 6),
                ],
                Text(
                  '${choice.flag} ${choice.name} · ${choice.currency}',
                  style: AppTypography.caption(Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
