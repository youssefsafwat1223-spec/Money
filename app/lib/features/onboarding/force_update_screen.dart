import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';

class ForceUpdateScreen extends ConsumerWidget {
  const ForceUpdateScreen({super.key});

  static const _appStoreUrl =
      'https://apps.apple.com/app/mali/id0000000000'; // update with real ID

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).extension<AppColors>()!;
    final announcementsAsync = ref.watch(activeAnnouncementsProvider);
    final announcement = announcementsAsync.valueOrNull
        ?.where((a) => a.isForceUpdate)
        .firstOrNull;

    final titleText = announcement?.titleAr ?? 'تحديث مطلوب';
    final bodyText =
        announcement?.bodyAr ?? 'يرجى تحديث التطبيق للاستمرار في الاستخدام.';
    final actionUrl = announcement?.actionUrl ?? _appStoreUrl;
    final actionLabel = announcement?.actionLabelAr ?? 'تحديث الآن';

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(AppLucideIcons.download, size: 72, color: c.primary),
              const SizedBox(height: AppSpacing.s5),
              Text(
                titleText,
                style: AppTypography.title1(c.textMain),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.s3),
              Text(
                bodyText,
                style: AppTypography.body(c.textLight),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => launchUrl(
                  Uri.parse(actionUrl),
                  mode: LaunchMode.externalApplication,
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: c.cta,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                child: Text(
                  actionLabel,
                  style: AppTypography.bodyStrong(Colors.white),
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
            ],
          ),
        ),
      ),
    );
  }
}
