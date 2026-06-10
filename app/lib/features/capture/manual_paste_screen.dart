import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../domain/usecases/add_transaction_usecase.dart';
import '../dashboard/dashboard_providers.dart';
import '../transactions/transactions_providers.dart';
import '../transactions/widgets/confirm_transaction_sheet.dart';

class ManualPasteScreen extends ConsumerStatefulWidget {
  const ManualPasteScreen({super.key});

  @override
  ConsumerState<ManualPasteScreen> createState() => _ManualPasteScreenState();
}

class _ManualPasteScreenState extends ConsumerState<ManualPasteScreen> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _controller.text = data!.text!;
    }
  }

  Future<void> _analyze() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);

    final result =
        await ref.read(addTransactionUseCaseProvider)(rawMessage: text);

    if (!mounted) return;
    setState(() => _busy = false);

    switch (result.outcome) {
      case AddTransactionOutcome.added:
        refreshTransactions(ref);
        ref.invalidate(dashboardDataProvider);
        await showConfirmTransactionSheet(context, result.transaction!.id);
        if (mounted) Navigator.of(context).pop();
      case AddTransactionOutcome.duplicate:
        _snack('هذه العملية مسجّلة بالفعل.');
      case AddTransactionOutcome.notTransaction:
        _snack('ما قدرنا نقرأها كعملية — تأكّد من نص الرسالة.');
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(title: const Text('ألصق رسالة البنك')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              maxLines: 6,
              style: AppTypography.body(c.textMain),
              decoration: InputDecoration(
                hintText: 'الصق نص رسالة البنك هنا...',
                filled: true,
                fillColor: c.surface2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(color: c.border),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            OutlinedButton.icon(
              onPressed: _pasteFromClipboard,
              icon: const Icon(AppLucideIcons.clipboardPaste, size: 18),
              label: const Text('لصق من الحافظة'),
            ),
            const Spacer(),
            SizedBox(
              height: 56,
              child: FilledButton(
                onPressed: _busy ? null : _analyze,
                style: FilledButton.styleFrom(
                  backgroundColor: c.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md)),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.white),
                      )
                    : Text('حلّل وأضف',
                        style: AppTypography.bodyStrong(Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
