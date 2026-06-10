import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import 'services/android_sms_capture_service.dart';

class SmsPermissionScreen extends StatefulWidget {
  const SmsPermissionScreen({super.key});

  @override
  State<SmsPermissionScreen> createState() => _SmsPermissionScreenState();
}

class _SmsPermissionScreenState extends State<SmsPermissionScreen> {
  bool _busy = false;

  Future<void> _request() async {
    if (_busy || !Platform.isAndroid) {
      return;
    }
    setState(() => _busy = true);
    final granted = await AndroidSmsCaptureService.instance.requestPermissions();
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    if (granted) {
      Navigator.of(context).pop(true);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('لم يتم تفعيل قراءة الرسائل حتى الآن.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Scaffold(
      appBar: AppBar(title: const Text('تفعيل الالتقاط التلقائي')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.s5),
              CircleAvatar(
                radius: 34,
                backgroundColor: c.primary.withValues(alpha: 0.12),
                child: Icon(
                  AppLucideIcons.receipt,
                  color: c.primary,
                  size: 28,
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
              Text(
                'فعّل التتبّع التلقائي',
                textAlign: TextAlign.center,
                style: AppTypography.title1(c.textMain),
              ),
              const SizedBox(height: AppSpacing.s2),
              Text(
                'نقرأ رسائل بنكك ونحلّلها على جهازك فقط.',
                textAlign: TextAlign.center,
                style: AppTypography.callout(c.textLight),
              ),
              const SizedBox(height: AppSpacing.s5),
              Container(
                padding: const EdgeInsets.all(AppSpacing.s4),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  border: Border.all(color: c.border),
                ),
                child: Column(
                  children: [
                    Text(
                      'مثال: «شراء 45 ريال لدى BURGER BOUTIQUE»',
                      textAlign: TextAlign.center,
                      style: AppTypography.bodyStrong(c.textMain),
                    ),
                    const SizedBox(height: AppSpacing.s2),
                    Text(
                      'نضيفها ونصنّفها لك، وإن احتاجت مراجعة سنطلب منك التأكيد فقط.',
                      textAlign: TextAlign.center,
                      style: AppTypography.callout(c.textLight),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              SizedBox(
                height: 56,
                child: FilledButton(
                  onPressed: _busy ? null : _request,
                  style: FilledButton.styleFrom(
                    backgroundColor: c.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          'السماح بقراءة الرسائل',
                          style: AppTypography.bodyStrong(Colors.white),
                        ),
                ),
              ),
              const SizedBox(height: AppSpacing.s2),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(
                  'لاحقًا، ألصق يدويًا',
                  style: AppTypography.bodyStrong(c.textLight),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
