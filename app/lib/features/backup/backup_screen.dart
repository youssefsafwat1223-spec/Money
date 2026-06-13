import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/backup/backup_service.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../common/section_hero_header.dart';

class BackupScreen extends ConsumerWidget {
  const BackupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(backupStatusProvider);
    final c = context.colors;
    final isGuest = AppSession.instance.isGuest;
    return Scaffold(
      backgroundColor: c.bg,
      body: Column(
        children: [
          const SectionHeroHeader(
            title: 'النسخ الاحتياطي والاستعادة',
            subtitle:
                'احفظ بياناتك المالية واسترجعها بأمان وسرية تامة في أي وقت.',
          ),
          Expanded(
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('حدث خطأ: $e')),
              data: (status) => isGuest
                  ? const _GuestBackupGate()
                  : status.enabled
                  ? _EnabledView(status: status)
                  : const _EnableFlow(),
            ),
          ),
        ],
      ),
    );
  }
}

class _GuestBackupGate extends StatelessWidget {
  const _GuestBackupGate();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        Icon(Icons.person_add_alt_1_outlined, size: 48, color: c.primary),
        const SizedBox(height: AppSpacing.s3),
        Text('أنشئ حسابًا لتفعيل النسخ الاحتياطي',
            style: AppTypography.headline(c.textMain)),
        const SizedBox(height: AppSpacing.s2),
        Text(
          'تقدر تستخدم مالي محليًا بدون حساب. النسخ الاحتياطي يحتاج تسجيل دخول حتى نربط النسخة المشفّرة بك.',
          style: AppTypography.body(c.textLight),
        ),
        const SizedBox(height: AppSpacing.s5),
        FilledButton(
          onPressed: () => context.push('/onboarding/auth'),
          child: const Text('تسجيل الدخول'),
        ),
      ],
    );
  }
}

class _EnabledView extends ConsumerWidget {
  const _EnabledView({required this.status});

  final BackupStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        Row(
          children: [
            Icon(Icons.cloud_done_outlined, color: c.success),
            const SizedBox(width: AppSpacing.s3),
            Text('النسخ الاحتياطي مفعّل',
                style: AppTypography.headline(c.textMain)),
          ],
        ),
        const SizedBox(height: AppSpacing.s2),
        Text(
          status.lastBackupAt == null
              ? 'لم تُنشأ نسخة بعد'
              : 'آخر نسخة: ${Formatters.fullDate(status.lastBackupAt!, context)} · ${Formatters.time(status.lastBackupAt!)}',
          style: AppTypography.body(c.textLight),
        ),
        const SizedBox(height: AppSpacing.s5),
        FilledButton(
          onPressed: () async {
            await ref.read(backupServiceProvider).backupNow();
            ref.invalidate(backupStatusProvider);
          },
          child: const Text('نسخ احتياطي الآن'),
        ),
        const SizedBox(height: AppSpacing.s3),
        const _RestoreBackupButton(),
        const SizedBox(height: AppSpacing.s3),
        OutlinedButton(
          onPressed: () async {
            await ref.read(backupServiceProvider).disable();
            ref.invalidate(backupStatusProvider);
          },
          child:
              Text('إيقاف النسخ الاحتياطي', style: TextStyle(color: c.danger)),
        ),
        const SizedBox(height: AppSpacing.s3),
        Text('بياناتك المحلية تبقى عند الإيقاف.',
            style: AppTypography.caption(c.textLight)),
      ],
    );
  }
}

class _EnableFlow extends ConsumerStatefulWidget {
  const _EnableFlow();

  @override
  ConsumerState<_EnableFlow> createState() => _EnableFlowState();
}

class _EnableFlowState extends ConsumerState<_EnableFlow> {
  final _passphrase = TextEditingController();
  String? _recoveryCode;
  bool _saved = false;
  bool _busy = false;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_passphrase.text.length < 6 || _busy) return;
    setState(() => _busy = true);
    final code = await ref
        .read(backupServiceProvider)
        .enable(passphrase: _passphrase.text);
    setState(() {
      _busy = false;
      _recoveryCode = code;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        Icon(Icons.lock_outline, size: 48, color: c.primary),
        const SizedBox(height: AppSpacing.s3),
        Text('نسخة مشفّرة لا نقدر نقرأها',
            style: AppTypography.headline(c.textMain)),
        const SizedBox(height: AppSpacing.s2),
        Text(
            'النسخ الاحتياطي اختياري ومطفأ افتراضياً. عند تفعيله تُشفّر بياناتك end-to-end وترجع على أي جهاز.',
            style: AppTypography.body(c.textLight)),
        const SizedBox(height: AppSpacing.s5),
        if (_recoveryCode == null) ...[
          Text('كلمة مرور التشفير (passphrase)',
              style: AppTypography.subhead(c.textLight)),
          const SizedBox(height: AppSpacing.s2),
          TextField(
            controller: _passphrase,
            obscureText: true,
            style: AppTypography.body(c.textMain),
            decoration: InputDecoration(
              filled: true,
              fillColor: isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : c.surface2.withValues(alpha: 0.5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: c.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: c.border.withValues(alpha: 0.5)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: c.primary, width: 2),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _busy ? null : _generate,
              style: FilledButton.styleFrom(
                backgroundColor: c.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child:
                  Text('متابعة', style: AppTypography.bodyStrong(Colors.white)),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          const _RestoreBackupButton(),
        ] else ...[
          Text('رمز الاسترداد (Recovery Code)',
              style: AppTypography.subhead(c.textLight)),
          const SizedBox(height: AppSpacing.s2),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: c.border, style: BorderStyle.solid),
            ),
            child: Center(
              child: SelectableText(_recoveryCode!,
                  style: AppTypography.title2(c.textMain)),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          OutlinedButton.icon(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: _recoveryCode!)),
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('نسخ الرمز'),
          ),
          const SizedBox(height: AppSpacing.s4),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s3),
            decoration: BoxDecoration(
              color: c.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: c.accent, size: 20),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: Text(
                    'لو فقدت كلمة المرور والرمز معاً لن نتمكّن من استعادة نسختك.',
                    style: AppTypography.caption(c.textMain),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          CheckboxListTile(
            value: _saved,
            onChanged: (v) => setState(() => _saved = v ?? false),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: c.primary,
            title: Text('حفظت الرمز وأفهم ذلك',
                style: AppTypography.body(c.textMain)),
          ),
          const SizedBox(height: AppSpacing.s3),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _saved
                  ? () {
                      ref.invalidate(backupStatusProvider);
                      Navigator.of(context).pop();
                    }
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: c.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child:
                  Text('تفعيل', style: AppTypography.bodyStrong(Colors.white)),
            ),
          ),
        ],
      ],
    );
  }
}

class _RestoreBackupButton extends StatelessWidget {
  const _RestoreBackupButton();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return OutlinedButton.icon(
      onPressed: () => context.push('/backup/restore'),
      icon: const Icon(Icons.restore_rounded, size: 18),
      label: Text(
        'استعادة من نسخة احتياطية',
        style: AppTypography.bodyStrong(c.primary),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: c.primary,
        side: BorderSide(color: c.primary.withValues(alpha: 0.35)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
    );
  }
}
