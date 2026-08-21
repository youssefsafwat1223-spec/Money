import 'package:flutter/material.dart';

/// The pre-ad notice shown immediately before a report-export interstitial.
///
/// It is deliberately restrained and carries NO rewarded-ad language: the ad is
/// never something the user "watches to unlock" or "completes to earn" the
/// report — the report is generated either way (fail-open). The copy says the
/// ad *may* appear because a no-fill / load failure / lifecycle interruption
/// still proceeds straight to generation.
///
/// The coordinator calls this only after every real gate has passed and an
/// interstitial is loaded, so an ad-free, offline or flag-off user never sees it.
///
/// Returns true to continue with the attempt, false to cancel it.
Future<bool> showReportAdNotice(BuildContext context) async {
  final isAr = Localizations.localeOf(context).languageCode != 'en';
  final result = await showDialog<bool>(
    context: context,
    // A stray barrier tap must not be read as consent; it maps to cancel below.
    barrierDismissible: true,
    builder: (dialogContext) => AlertDialog(
      title: Text(isAr ? 'إعلان قبل إنشاء التقرير' : 'Ad before your report'),
      content: Text(
        isAr
            ? 'قد يظهر إعلان قصير قبل إنشاء التقرير.'
            : 'A short ad may appear before your report is created.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(isAr ? 'إلغاء' : 'Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(isAr ? 'متابعة' : 'Continue'),
        ),
      ],
    ),
  );
  // Null (barrier dismissal / system pop) is treated as cancellation, never as
  // consent — the coordinator then ends the attempt cleanly at idle.
  return result ?? false;
}
