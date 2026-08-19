import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../cards/brand_mark.dart';
import 'app_avatar.dart';

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
    this.categoryIconName,
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
    this.horizontalPadding = AppSpacing.gutter,
  });

  final String title;
  final double amount;
  final String currency;
  final String? subtitle;
  final IconData? categoryIcon;
  final String? categoryIconName;
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

  /// Horizontal inset. Full [AppSpacing.gutter] on a bare list; smaller when
  /// the row sits inside a day card.
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final formattedAmount =
        privacyMode ? '••••' : '${Formatters.amount(amount)} $currency';
    // Calm Capital ledger: expense stays neutral (primary text), income green.
    final amountColor = isDebit ? c.textPrimary : c.success;
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
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: AppSpacing.s2,
            ),
            child: Row(
              children: [
                (brandLogoUrl != null || BrandMark.hasBrand(title))
                    ? AppAvatar.brand(name: title, logoUrl: brandLogoUrl)
                    : categoryIcon != null
                        ? AppAvatar.icon(
                            icon: categoryIcon!, color: categoryColor)
                        : AppAvatar.category(
                            iconName: categoryIconName,
                            color: categoryColor,
                          ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: AppTypography.bodyStrong(c.textPrimary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isPending)
                            _RowBadge(label: 'قيد المراجعة', color: c.warning),
                          if (isAi) _RowBadge(label: 'ذكاء', color: c.cta),
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
                      privacyMode
                          ? '••••'
                          : '$amountPrefix${Formatters.amount(amount)}',
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

/// Compact tinted pill for a ledger row (قيد المراجعة / ذكاء) — matches the
/// Calm Capital mockup: colored text on a soft same-color tint.
class _RowBadge extends StatelessWidget {
  const _RowBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          label,
          style:
              AppTypography.micro(color).copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
