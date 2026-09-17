import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import 'manual_paste_screen.dart';
import '../../core/utils/l10n_ext.dart';

class SmsPermissionScreen extends StatefulWidget {
  const SmsPermissionScreen({super.key});

  static Future<void> showSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => navySheetTheme(const FractionallySizedBox(
        heightFactor: 0.82,
        child: SmsPermissionScreen(),
      )),
    );
  }

  @override
  State<SmsPermissionScreen> createState() => _SmsPermissionScreenState();
}

class _SmsPermissionScreenState extends State<SmsPermissionScreen> {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Directionality(
      textDirection: Directionality.of(context),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(28),
        ),
        child: MaliGlass(
          variant: MaliGlassVariant.sheet,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s3,
              AppSpacing.gutter,
              AppSpacing.s6,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: c.textLight.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    // DIRECTIONAL. `Alignment.topLeft` is absolute, so the
                    // close button sat on the left in BOTH languages — correct
                    // for Arabic by coincidence, wrong for English. Every
                    // other sheet in the app puts close at the END.
                    alignment: AlignmentDirectional.topEnd,
                    child: IconButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      icon: const Icon(AppLucideIcons.x),
                      style: IconButton.styleFrom(
                        backgroundColor: c.surface.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.s3),
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
                  context.l10n.smsShareTitle,
                  textAlign: TextAlign.center,
                  style: AppTypography.title1(c.textMain),
                ),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  context.l10n.smsShareBody,
                  textAlign: TextAlign.center,
                  style: AppTypography.callout(c.textLight),
                ),
                const SizedBox(height: AppSpacing.s5),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.s4),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : c.surface2.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color:
                          Colors.white.withValues(alpha: isDark ? 0.08 : 0.4),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        context.l10n.smsShareExample,
                        textAlign: TextAlign.center,
                        style: AppTypography.bodyStrong(c.textMain),
                      ),
                      const SizedBox(height: AppSpacing.s2),
                      Text(
                        context.l10n.smsShareFallback,
                        textAlign: TextAlign.center,
                        style: AppTypography.callout(c.textLight),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      ManualPasteScreen.showSheet(context);
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: c.cta,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Text(
                      context.l10n.smsPasteManually,
                      style: AppTypography.bodyStrong(Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(
                    context.l10n.smsPasteLater,
                    style: AppTypography.bodyStrong(c.textLight),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
