import 'dart:ui';
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

  static Future<void> showSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ManualPasteSheet(),
    );
  }

  @override
  ConsumerState<ManualPasteScreen> createState() => _ManualPasteScreenState();
}

class _ManualPasteSheet extends StatelessWidget {
  const _ManualPasteSheet();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(28),
        ),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: MediaQuery.of(context).size.height * 0.78,
            decoration: BoxDecoration(
              color: isDark ? c.surface.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.92),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.3),
                width: 1.5,
              ),
            ),
            child: Column(
              children: [
                const SizedBox(height: AppSpacing.s3),
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: c.textLight.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.gutter,
                    AppSpacing.s4,
                    AppSpacing.gutter,
                    AppSpacing.s2,
                  ),
                  child: Row(
                    children: [
                      Text('ألصق رسالة البنك',
                          style: AppTypography.title2(c.textMain)),
                      const Spacer(),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                        style: IconButton.styleFrom(
                          backgroundColor: c.surface.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                ),
                const Expanded(child: _ManualPasteContent(fullScreen: false)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ManualPasteScreenState extends ConsumerState<ManualPasteScreen> {
  @override
  Widget build(BuildContext context) => const _ManualPasteContent();
}

class _ManualPasteContent extends ConsumerStatefulWidget {
  const _ManualPasteContent({this.fullScreen = true});

  final bool fullScreen;

  @override
  ConsumerState<_ManualPasteContent> createState() =>
      _ManualPasteContentState();
}

class _ManualPasteContentState extends ConsumerState<_ManualPasteContent> {
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final content = Padding(
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
                fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : c.surface2.withValues(alpha: 0.5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: c.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: c.border.withValues(alpha: 0.5)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: c.primary, width: 2),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            OutlinedButton.icon(
              onPressed: _pasteFromClipboard,
              icon: const Icon(AppLucideIcons.clipboardPaste, size: 18),
              label: const Text('لصق من الحافظة'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                side: BorderSide(color: c.border.withValues(alpha: 0.5)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            const Spacer(),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: _busy ? null : _analyze,
                style: FilledButton.styleFrom(
                  backgroundColor: c.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
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
      );
    if (!widget.fullScreen) return content;
    return Scaffold(
      appBar: AppBar(title: const Text('ألصق رسالة البنك')),
      body: content,
    );
  }
}

