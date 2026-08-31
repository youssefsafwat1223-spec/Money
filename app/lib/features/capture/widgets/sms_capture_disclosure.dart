import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

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
        'قراءة رسائل البنك تلقائياً',
        style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'عشان قِرش يسجّل مصاريفك تلقائياً، محتاج إذن قراءة الرسائل '
              'الواردة على جهازك.',
              style: text.bodyMedium?.copyWith(color: c.textPrimary),
            ),
            const SizedBox(height: 16),
            point(
              Icons.search,
              'قِرش يفحص الرسائل الواردة عشان يتعرّف على العمليات المالية '
              '(شراء، تحويل، سحب، إيداع).',
            ),
            point(
              Icons.filter_alt_outlined,
              'الرسائل غير المالية — الشخصية ورموز التحقق — بتتجاهَل ومابتتخزّنش.',
            ),
            point(
              Icons.phone_iphone,
              'التحليل بيتم على جهازك. مفيش نص رسالة بيتبعت لأي مزوّد ذكاء '
              'اصطناعي.',
            ),
            point(
              Icons.cloud_off_outlined,
              'المزامنة السحابية مقفولة افتراضياً، ولو شغّلتها بتبقى بموافقة '
              'منفصلة عن الإذن ده.',
            ),
            point(
              Icons.toggle_off_outlined,
              'تقدر توقف القراءة التلقائية من إعدادات قِرش، أو تسحب الإذن من '
              'إعدادات الجهاز، في أي وقت.',
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('مش دلوقتي', style: TextStyle(color: c.textSecondary)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('موافق، اطلب الإذن'),
        ),
      ],
    );
  }
}
