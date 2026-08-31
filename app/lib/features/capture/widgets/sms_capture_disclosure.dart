import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/l10n_ext.dart';

/// MALI-013 — the prominent disclosure shown immediately before the Android
/// RECEIVE_SMS runtime dialog.
///
/// Google Play requires a prominent disclosure *before* the system permission
/// prompt for a restricted permission, and requires it to state what is
/// accessed, why, and how it is handled. A dialog shown after the prompt, or
/// one that bundles unrelated consent, is a policy violation even if the user
/// agrees.
///
/// Rules this deliberately follows:
///   • It asks for ONE thing. No cloud sync, no analytics, no marketing opt-in
///     is bundled here — bundling is exactly what makes a disclosure invalid.
///   • Every string is localised. Qirsh ships an English UI as well as Arabic,
///     and a disclosure the user cannot read is not a disclosure — Play requires
///     it to be understandable, not merely present.
///   • Dismissing it (tap-outside / back) counts as DECLINE, not accept.
///   • It never claims more privacy than the app delivers. Cloud processing is
///     described as possible-but-separately-consented rather than impossible,
///     because an optional consented path does exist.
///
/// Returns `true` only on an explicit affirmative action.
Future<bool> showSmsCaptureDisclosure(BuildContext context) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: true, // dismissing means decline — handled below
    builder: (context) => const _SmsCaptureDisclosureDialog(),
  );
  return accepted ?? false;
}

class _SmsCaptureDisclosureDialog extends StatelessWidget {
  const _SmsCaptureDisclosureDialog();

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>() ?? AppColors.light;
    final text = Theme.of(context).textTheme;
    final l10n = context.l10n;

    Widget point(IconData icon, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: c.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  body,
                  style: text.bodyMedium?.copyWith(color: c.textSecondary),
                ),
              ),
            ],
          ),
        );

    return AlertDialog(
      backgroundColor: c.surfaceCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        l10n.smsDisclosureTitle,
        style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.smsDisclosureIntro,
              style: text.bodyMedium?.copyWith(color: c.textPrimary),
            ),
            const SizedBox(height: 16),
            point(
              Icons.search,
              l10n.smsDisclosureDetect,
            ),
            point(
              Icons.filter_alt_outlined,
              l10n.smsDisclosureFilter,
            ),
            point(
              Icons.phone_iphone,
              l10n.smsDisclosureOnDevice,
            ),
            point(
              Icons.cloud_off_outlined,
              l10n.smsDisclosureCloud,
            ),
            point(
              Icons.toggle_off_outlined,
              l10n.smsDisclosureControl,
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.smsDisclosureDecline,
              style: TextStyle(color: c.textSecondary)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.smsDisclosureAccept),
        ),
      ],
    );
  }
}
