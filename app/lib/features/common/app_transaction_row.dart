import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';

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
    this.isPending = false,
    this.isAi = false,
    this.confidencePercent,
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
  final bool isPending;
  final bool isAi;
  final int? confidencePercent;
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
                _CategoryAvatar(icon: categoryIcon, color: categoryColor, c: c),
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
                            _Badge(
                              label: 'معلق',
                              bg: c.warning.withValues(alpha: 0.15),
                              fg: c.warning,
                            ),
                          if (isAi)
                            Padding(
                              padding:
                                  const EdgeInsetsDirectional.only(start: 4),
                              child: _Badge(
                                label: 'ذكي',
                                bg: c.accent.withValues(alpha: 0.15),
                                fg: c.accent,
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

class _CategoryAvatar extends StatelessWidget {
  const _CategoryAvatar({
    required this.icon,
    required this.color,
    required this.c,
  });

  final IconData? icon;
  final Color? color;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    final bg = (color ?? c.cta).withValues(alpha: 0.12);
    final fg = color ?? c.cta;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Icon(icon ?? Icons.receipt_outlined, size: 18, color: fg),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.bg, required this.fg});

  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: AppTypography.caption(fg).copyWith(fontSize: 11),
      ),
    );
  }
}
