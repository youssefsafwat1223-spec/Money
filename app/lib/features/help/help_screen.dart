import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';
import '../common/app_card.dart';
import '../common/app_screen_scaffold.dart';

/// V1 guidance, Layer B (charter: REQUIRED_PRODUCT_CHANGE_5).
///
/// The persistent, re-openable half of the guidance contract. Layer A's coach
/// marks appear once on first use and then get out of the way; this screen is
/// where someone comes back after they have forgotten something, so it is
/// reachable from Settings at any time and is never dismissed permanently.
///
/// Every string is localised. This is the one screen where a hardcoded Arabic
/// literal would be most obviously wrong, since its entire purpose is to explain
/// the product to someone who may be reading it in either language.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;

    final sections = <_HelpSection>[
      _HelpSection(l10n.helpSectionBasics, [
        _HelpEntry(AppLucideIcons.plus, l10n.helpAddTransactionTitle,
            l10n.helpAddTransactionBody),
        _HelpEntry(AppLucideIcons.inbox, l10n.helpSmartInboxTitle,
            l10n.helpSmartInboxBody),
        _HelpEntry(
            AppLucideIcons.tag, l10n.helpCategoriesTitle, l10n.helpCategoriesBody),
      ]),
      _HelpSection(l10n.helpSectionReports, [
        _HelpEntry(AppLucideIcons.calendarCheck, l10n.helpPeriodTitle,
            l10n.helpPeriodBody),
        _HelpEntry(
            AppLucideIcons.lineChart, l10n.helpAnnualTitle, l10n.helpAnnualBody),
      ]),
      _HelpSection(l10n.helpSectionPlanning, [
        _HelpEntry(AppLucideIcons.wallet, l10n.helpAccountsTitle,
            l10n.helpAccountsBody),
        _HelpEntry(
            AppLucideIcons.target, l10n.helpBudgetsTitle, l10n.helpBudgetsBody),
        _HelpEntry(AppLucideIcons.flag, l10n.helpGoalsTitle, l10n.helpGoalsBody),
      ]),
      _HelpSection(l10n.helpSectionPrivacy, [
        _HelpEntry(AppLucideIcons.shieldCheck, l10n.helpPrivacyTitle,
            l10n.helpPrivacyBody),
        _HelpEntry(AppLucideIcons.download, l10n.helpBackupTitle,
            l10n.helpBackupBody),
      ]),
    ];

    return AppScreenScaffold(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter, AppSpacing.s3, AppSpacing.gutter, AppSpacing.s2),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.helpTitle,
                    style: AppTypography.calmTitle(c.textPrimary)
                        .copyWith(fontSize: 24, letterSpacing: -0.5),
                  ),
                  const SizedBox(height: AppSpacing.s1),
                  Text(
                    l10n.helpSubtitle,
                    style: AppTypography.caption(c.textMuted),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(AppLucideIcons.x),
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            ),
          ],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      body: ListView(
        children: [
          for (final section in sections) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s1, AppSpacing.s4, AppSpacing.s1, AppSpacing.s2),
              child: Text(
                section.title,
                style: AppTypography.sectionTitle(c.textMain),
              ),
            ),
            for (final entry in section.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.s2),
                child: AppCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(entry.icon, size: 20, color: c.primary),
                      const SizedBox(width: AppSpacing.s3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(entry.title,
                                style: AppTypography.bodyStrong(c.textMain)),
                            const SizedBox(height: AppSpacing.s1),
                            Text(entry.body,
                                style: AppTypography.caption(c.textLight)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          const SizedBox(height: AppSpacing.s4),
          Text(
            l10n.helpFooter,
            textAlign: TextAlign.center,
            style: AppTypography.caption(c.textMuted),
          ),
          const SizedBox(height: AppSpacing.s6),
        ],
      ),
    );
  }
}

class _HelpSection {
  const _HelpSection(this.title, this.entries);
  final String title;
  final List<_HelpEntry> entries;
}

class _HelpEntry {
  const _HelpEntry(this.icon, this.title, this.body);
  final IconData icon;
  final String title;
  final String body;
}
