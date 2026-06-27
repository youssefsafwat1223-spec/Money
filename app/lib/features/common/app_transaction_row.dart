import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../cards/brand_mark.dart';
import 'app_status_pill.dart';
import 'category_avatar.dart';

/// صف معاملة قياسي — UI فقط، لا يستورد طبقة البيانات.
///
/// يدعم بادج "معلق"، بادج "ذكاء اصطناعي"، وضع الخصوصية، RTL، والوصول.
/// الحد الأدنى لمنطقة النقر 44px وفق إرشادات iOS/Material.
///
/// لا يُلغي [TransactionRow] الموجود — مكوّن جديد للاستخدام في الشاشات
/// القادمة (المراحل 4-9).
class AppTransactionRow extends StatelessWidget {
  const AppTransactionRow({
    super.key,
    required this.title,
    required this.amount,
    required this.currency,
    this.subtitle,
    this.categoryIcon,
    this.categoryColor,
    this.brandLogoUrl,
    this.isPending = false,
    this.isAi = false,
    this.confidencePercent,
    this.isConfirmed = true,
    this.onTap,
    this.trailing,
    this.privacyMode = false,
    this.isDebit = true,
    this.semanticsLabel,
  });

  final String title;
  final double amount;
  final String currency;
  final String? subtitle;
  final IconData? categoryIcon;
  final Color? categoryColor;

  /// Admin-managed brand logo URL (resolved by the caller). When set, shows the
  /// brand logo instead of the category icon.
  final String? brandLogoUrl;
  final bool isPending;
  final bool isAi;
  final int? confidencePercent;
  final bool isConfirmed;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool privacyMode;
  final bool isDebit;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final formattedAmount =
        privacyMode ? '••••' : '${Formatters.amount(amount)} $currency';
    final amountColor = isDebit ? c.danger : c.success;
    final amountPrefix = isDebit ? '−' : '+';

    final semantics = semanticsLabel ??
        '$title، ${isDebit ? 'خصم' : 'إيداع'} $formattedAmount'
            '${isPending ? '، معلق' : ''}'
            '${isAi ? '، ذكاء اصطناعي' : ''}';

    return Semantics(
      label: semantics,
      button: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.gutter,
              vertical: AppSpacing.s3,
            ),
            child: Row(
              children: [
                (brandLogoUrl != null || BrandMark.hasBrand(title))
                    ? BrandMark(name: title, size: 44, logoUrl: brandLogoUrl)
                    : CategoryAvatar(icon: categoryIcon, color: categoryColor),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: AppTypography.subhead(c.textPrimary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isPending)
                            const AppStatusPill(
                              label: 'معلق',
                              tone: AppStatusTone.pending,
                              compact: true,
                            )
                          else if (isConfirmed)
                            const AppStatusPill(
                              label: 'مؤكد',
                              tone: AppStatusTone.confirmed,
                              compact: true,
                            ),
                          if (isAi)
                            const Padding(
                              padding: EdgeInsetsDirectional.only(start: 4),
                              child: AppStatusPill(
                                label: 'ذكي',
                                tone: AppStatusTone.info,
                                compact: true,
                              ),
                            ),
                        ],
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: AppTypography.caption(c.textMuted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                trailing ??
                    Text(
                      privacyMode ? '••••' : '$amountPrefix$formattedAmount',
                      style: AppTypography.bodyStrong(
                          privacyMode ? c.textMuted : amountColor),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
