import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/widgets/glass_sheet.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../common/app_header.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/session/app_session.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/theme/widgets/app_toast.dart';
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
      header: AppHeader(title: l10n.helpTitle),
      body: ListView(
        children: [
          const Center(
            child: QirshIllustration(name: 'help', width: 220, height: 165),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s3),
            child: Text(l10n.helpSubtitle,
                textAlign: TextAlign.center,
                style: AppTypography.callout(c.textMuted)),
          ),
          for (final section in sections) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
              child: Text(section.title,
                  style: AppTypography.caption(c.textMuted)
                      .copyWith(fontWeight: FontWeight.w700)),
            ),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final entry in section.entries) ...[
                    if (entry != section.entries.first)
                      Divider(height: 1, color: c.border, indent: 16, endIndent: 16),
                    ExpansionTile(
                      initiallyExpanded: entry == sections.first.entries.first,
                      maintainState: true,
                      shape: const Border(),
                      collapsedShape: const Border(),
                      iconColor: c.textMuted,
                      collapsedIconColor: c.textMuted,
                      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                      childrenPadding: const EdgeInsetsDirectional.fromSTEB(
                          16, 0, 16, 16),
                      title: Text(entry.title,
                          style: AppTypography.custom(size: 14,
                              weight: FontWeight.w500, height: 1.4,
                              color: c.textPrimary)),
                      children: [
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(entry.body,
                              style: AppTypography.custom(size: 13,
                                  weight: FontWeight.w400, height: 1.7,
                                  color: c.textMuted)),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
            icon: const Icon(AppLucideIcons.messageSquare, size: 18),
            label: Text(l10n.setContactUs),
            onPressed: () => showGlassSheet<void>(
              context: context,
              showDragHandle: true,
              builder: (sheetContext) => Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l10n.setContactUs,
                        style: AppTypography.sectionTitle(c.textPrimary)),
                    const SizedBox(height: 12),
                    Text(l10n.setSupportBody,
                        style: AppTypography.callout(c.textSecondary)),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () async {
                        await Clipboard.setData(const ClipboardData(
                            text: 'support@money-companion.app'));
                        if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                      },
                      child: Text(l10n.setCopyEmail),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          // Someone who dismissed the first-use tour should not be locked out
          // of it forever — this is the only way back to Layer A.
          AppCard(
            onTap: () async {
              await AppSession.instance.resetCoachMarks();
              if (!context.mounted) return;
              AppToast.show(context, l10n.helpReplayTourDone);
            },
            child: Row(
              children: [
                Icon(AppLucideIcons.refreshCw, size: 20, color: c.primary),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Text(l10n.helpReplayTour,
                      style: AppTypography.bodyStrong(c.textMain)),
                ),
              ],
            ),
          ),
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
