import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../capture/services/captured_message_processor.dart';
import '../capture/services/local_notification_service.dart';
import '../capture/services/native_capture_bridge.dart';
import 'onboarding_options.dart';
import 'widgets/luxe_starry_bg.dart';

/// Page 4 of the redesigned onboarding: a single activation checklist.
///
/// Steps unlock top-to-bottom:
///   0. Country / currency   → saves the base currency (required for accounts)
///   1. Notifications        → OS permission prompt
///   2. Cloud processing     → enables backend + AI consent, then syncNativeState
///   3. Shortcut install     → instructions carousel, self-declared
///   4. Verify (optional)    → listens for the first captured transaction
///
/// The final "ابدأ" finishes onboarding and enters the app.
class OnboardingSetupScreen extends ConsumerStatefulWidget {
  const OnboardingSetupScreen({super.key});

  @override
  ConsumerState<OnboardingSetupScreen> createState() =>
      _OnboardingSetupScreenState();
}

class _CountryChoice {
  const _CountryChoice(this.code, this.flag, this.name, this.currency);
  final String code;
  final String flag;
  final String name;
  final String currency;
}

const _countries = <_CountryChoice>[
  _CountryChoice('SA', '🇸🇦', 'السعودية', 'SAR'),
  _CountryChoice('AE', '🇦🇪', 'الإمارات', 'AED'),
  _CountryChoice('EG', '🇪🇬', 'مصر', 'EGP'),
  _CountryChoice('KW', '🇰🇼', 'الكويت', 'KWD'),
  _CountryChoice('QA', '🇶🇦', 'قطر', 'QAR'),
  _CountryChoice('BH', '🇧🇭', 'البحرين', 'BHD'),
  _CountryChoice('OM', '🇴🇲', 'عُمان', 'OMR'),
  _CountryChoice('JO', '🇯🇴', 'الأردن', 'JOD'),
];

class _OnboardingSetupScreenState extends ConsumerState<OnboardingSetupScreen>
    with WidgetsBindingObserver {
  static const _stepCount = 5;

  final _done = List<bool>.filled(_stepCount, false);
  _CountryChoice _country = _countries.first;
  bool _busy = false;

  Timer? _verifyTimer;
  bool _verifyChecking = false;
  bool _verifyDetected = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _verifyTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _verifyTimer != null) {
      _pollVerify();
    }
  }

  bool get _canFinish => _done[0] && _done[1] && _done[2] && _done[3];
  int get _completed => _done.where((d) => d).length;

  void _markDone(int step) {
    if (!mounted) return;
    setState(() => _done[step] = true);
  }

  // ── Step 0: country / currency ────────────────────────────────────────
  Future<void> _saveCountry(_CountryChoice choice) async {
    setState(() {
      _country = choice;
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

  // ── Step 2: cloud processing + AI consent ─────────────────────────────
  Future<void> _enableCloud() async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(userSettingsRepositoryProvider);
      final settings = await repo.getSettings();
      await repo.saveSettings(settings.copyWith(
        cloudProcessingEnabled: true,
        aiConsentGranted: true,
      ));
      // NON-NEGOTIABLE: writes the App Group backend config, registers the
      // device, and uploads the APNs token. Without it the iOS Shortcut cannot
      // reach the backend. Best-effort — the app also re-syncs on every launch.
      try {
        await ref
            .read(captureDeviceRegistrationServiceProvider)
            .syncNativeState();
      } catch (_) {}
      _markDone(2);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Step 4: verify ────────────────────────────────────────────────────
  void _startVerify() {
    _verifyTimer ??=
        Timer.periodic(const Duration(seconds: 2), (_) => _pollVerify());
  }

  Future<void> _pollVerify() async {
    if (_verifyChecking || !mounted) return;
    _verifyChecking = true;
    try {
      final messages = await NativeCaptureBridge.consumePendingSharedMessages();
      for (final msg in messages) {
        final result = await CapturedMessageProcessor.process(
          rawMessage: msg.text,
          senderId: msg.sender,
          showNotifications: false,
        );
        if (result.transactionId != null && mounted) {
          _verifyTimer?.cancel();
          _verifyTimer = null;
          setState(() {
            _verifyDetected = true;
            _done[4] = true;
          });
          return;
        }
      }
    } finally {
      _verifyChecking = false;
    }
  }

  // ── Finish ────────────────────────────────────────────────────────────
  Future<void> _finish() async {
    setState(() => _busy = true);
    await AppSession.instance.finishOnboarding();
    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          const Positioned.fill(child: LuxeStarryBackground()),
          SafeArea(
            child: Column(
              children: [
                _header(c),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.gutter, 8, AppSpacing.gutter, 24),
                    children: [
                      _countryStep(c),
                      const SizedBox(height: AppSpacing.s3),
                      _actionStep(
                        c,
                        step: 1,
                        icon: Icons.notifications_active_outlined,
                        title: 'فعّل الإشعارات',
                        body: 'عشان توصلك كل عملية فور حدوثها.',
                        cta: 'تفعيل',
                        onTap: _enableNotifications,
                      ),
                      const SizedBox(height: AppSpacing.s3),
                      _actionStep(
                        c,
                        step: 2,
                        icon: Icons.cloud_done_outlined,
                        title: 'فعّل المعالجة الذكية',
                        body:
                            'بنحلل رسائل البنك ونسجل عملياتك تلقائياً. بتفعيلك بتوافق '
                            'على معالجة نصوص الرسائل سحابياً لتحليلها — بياناتك متشفرة '
                            'ولا نخزن أرقامك الكاملة.',
                        cta: 'موافق وفعّل',
                        onTap: _enableCloud,
                      ),
                      const SizedBox(height: AppSpacing.s3),
                      _shortcutStep(c),
                      const SizedBox(height: AppSpacing.s3),
                      _verifyStep(c),
                    ],
                  ),
                ),
                _finishBar(c),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, 16, AppSpacing.gutter, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('يلا نجهّز قِرش',
              style: AppTypography.title1(c.textMain)
                  .copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('كام خطوة سريعة وتكون جاهز.',
              style: AppTypography.caption(c.textLight)),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: _completed / _stepCount,
              minHeight: 6,
              backgroundColor: c.surface2,
              valueColor: AlwaysStoppedAnimation(c.primary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepCard(
    AppColors c, {
    required int step,
    required bool locked,
    required Widget child,
  }) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 250),
      opacity: locked ? 0.45 : 1,
      child: IgnorePointer(
        ignoring: locked,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.s4),
          decoration: BoxDecoration(
            color: c.surface.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
              color: _done[step]
                  ? c.primary.withValues(alpha: 0.5)
                  : c.border.withValues(alpha: 0.4),
            ),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _stepHeader(AppColors c,
      {required int step, required IconData icon, required String title}) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: c.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(_done[step] ? Icons.check_rounded : icon,
              color: c.primary, size: 20),
        ),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Text(title, style: AppTypography.bodyStrong(c.textMain)),
        ),
        if (_done[step])
          Icon(Icons.check_circle, color: c.success, size: 22),
      ],
    );
  }

  Widget _countryStep(AppColors c) {
    return _stepCard(
      c,
      step: 0,
      locked: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepHeader(c,
              step: 0, icon: Icons.public_rounded, title: 'دولتك وعملتك'),
          const SizedBox(height: 6),
          Text('بنستخدمها كعملة أساسية لحساباتك.',
              style: AppTypography.caption(c.textLight)),
          const SizedBox(height: AppSpacing.s3),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final choice in _countries)
                ChoiceChip(
                  label: Text('${choice.flag} ${choice.name} · ${choice.currency}'),
                  selected: _done[0] && _country.code == choice.code,
                  onSelected:
                      _busy ? null : (_) => _saveCountry(choice),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionStep(
    AppColors c, {
    required int step,
    required IconData icon,
    required String title,
    required String body,
    required String cta,
    required Future<void> Function() onTap,
  }) {
    final locked = !_done[step - 1];
    return _stepCard(
      c,
      step: step,
      locked: locked,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepHeader(c, step: step, icon: icon, title: title),
          const SizedBox(height: 8),
          Text(body, style: AppTypography.caption(c.textLight)),
          const SizedBox(height: AppSpacing.s3),
          if (!_done[step])
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : () => onTap(),
                style: FilledButton.styleFrom(
                  backgroundColor: c.primary,
                  minimumSize: const Size.fromHeight(46),
                ),
                child: Text(cta,
                    style: AppTypography.bodyStrong(Colors.white)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _shortcutStep(AppColors c) {
    const step = 3;
    final locked = !_done[step - 1];
    final steps = <(String, String)>[
      ('احذف القديم', 'افتح تطبيق Shortcuts وروح لتبويب Automation واحذف أي أتمتة قديمة للتطبيق.'),
      ('جديد (+)', 'اضغط New Automation (+) ومرّر للأسفل حتى تلقى «Message».'),
      ('حدّد الرسائل', 'اضغط «Message Contents» واكتب رمز عملتك مثل ${_country.currency}.'),
      ('بدون تأكيد', 'فعّل «Run Immediately» واقفل «Notify When Run» لو ظهر، ثم Next.'),
      ('إرسال للتطبيق', 'اختر New Blank Automation وابحث عن «Process Bank SMS»، وفي SMS Text اختر «Shortcut Input».'),
      ('حفظ', 'اقفل «Show When Run» لو ظهر، واضغط حفظ.'),
    ];
    return _stepCard(
      c,
      step: step,
      locked: locked,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepHeader(c,
              step: step,
              icon: Icons.ios_share_rounded,
              title: 'ثبّت اختصار قِرش'),
          const SizedBox(height: 6),
          Text('هو اللي بيبعتلنا رسائل البنك تلقائياً.',
              style: AppTypography.caption(c.textLight)),
          const SizedBox(height: AppSpacing.s3),
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
                    color: c.surface2.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${i + 1}. $title',
                          style: AppTypography.bodyStrong(c.textMain)),
                      const SizedBox(height: 6),
                      Expanded(
                        child: Text(body,
                            style: AppTypography.caption(c.textLight),
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          if (!_done[step])
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : () => _markDone(step),
                style: FilledButton.styleFrom(
                  backgroundColor: c.primary,
                  minimumSize: const Size.fromHeight(46),
                ),
                child: Text('ثبّتّه',
                    style: AppTypography.bodyStrong(Colors.white)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _verifyStep(AppColors c) {
    const step = 4;
    final locked = !_done[step - 1];
    return _stepCard(
      c,
      step: step,
      locked: locked,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepHeader(c,
              step: step,
              icon: Icons.wifi_tethering_rounded,
              title: 'جرّب بنفسك'),
          const SizedBox(height: 6),
          Text(
            _verifyDetected
                ? 'وصلت! قِرش سجّلها. ✓'
                : 'ابعت رسالة تجربة من الاختصار وسيب الباقي علينا.',
            style: AppTypography.caption(
                _verifyDetected ? c.success : c.textLight),
          ),
          const SizedBox(height: AppSpacing.s3),
          if (_verifyDetected)
            Icon(Icons.check_circle, color: c.success, size: 40)
                .animate()
                .scale(duration: 320.ms, curve: Curves.easeOutBack)
          else ...[
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(
                  _verifyTimer != null
                      ? 'بنستنى أول رسالة...'
                      : 'اضغط ابدأ الاستماع.',
                  style: AppTypography.caption(c.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s3),
            Row(
              children: [
                if (_verifyTimer == null)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _startVerify,
                      child: const Text('ابدأ الاستماع'),
                    ),
                  ),
                if (_verifyTimer == null) const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _markDone(step),
                  child: Text('تخطي دلوقتي',
                      style: AppTypography.caption(c.textLight)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _finishBar(AppColors c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, 8, AppSpacing.gutter, 16),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: (_canFinish && !_busy) ? _finish : null,
          style: FilledButton.styleFrom(
            backgroundColor: c.primary,
            minimumSize: const Size.fromHeight(54),
          ),
          child: Text('ابدأ',
              style: AppTypography.bodyStrong(Colors.white)),
        ),
      ),
    );
  }
}
