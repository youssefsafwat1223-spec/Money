import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../domain/entities/sender_bank_mapping_entity.dart';
import 'bank_discovery_controller.dart';

Future<void> showBankDiscoveryConfirmationSheet(
  BuildContext context,
  SenderBankMappingEntity mapping,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => navySheetTheme(
      BankDiscoveryConfirmationSheet(mapping: mapping),
    ),
  );
}

class BankDiscoveryConfirmationSheet extends ConsumerStatefulWidget {
  const BankDiscoveryConfirmationSheet({
    super.key,
    required this.mapping,
  });

  final SenderBankMappingEntity mapping;

  @override
  ConsumerState<BankDiscoveryConfirmationSheet> createState() =>
      _BankDiscoveryConfirmationSheetState();
}

class _BankDiscoveryConfirmationSheetState
    extends ConsumerState<BankDiscoveryConfirmationSheet> {
  bool _busy = false;

  Future<void> _confirm() async {
    await _run(() async {
      await _controller.confirm(widget.mapping);
      await ref.read(senderBankMappingSyncServiceProvider)?.uploadPending();
    });
  }

  Future<void> _reject() async {
    await _run(() async {
      await _controller.reject(widget.mapping);
      await ref.read(senderBankMappingSyncServiceProvider)?.uploadPending();
    });
  }

  Future<void> _askLater() async {
    await _run(() async {
      await _controller.askLater(widget.mapping);
    });
  }

  BankDiscoveryController get _controller => BankDiscoveryController(
        repository: ref.read(senderBankMappingRepositoryProvider),
      );

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mapping = widget.mapping;
    final confidence = (mapping.confidence * 100).round();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Material(
            color: isDark
                ? c.surface.withValues(alpha: 0.94)
                : Colors.white.withValues(alpha: 0.96),
            shape: RoundedRectangleBorder(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
              side: BorderSide(color: c.border.withValues(alpha: 0.8)),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.s3,
                  AppSpacing.gutter,
                  AppSpacing.s5,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: c.textLight.withValues(alpha: 0.28),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    Text(
                      'تأكيد البنك',
                      textAlign: TextAlign.center,
                      style: AppTypography.subhead(c.textLight),
                    ),
                    const SizedBox(height: AppSpacing.s2),
                    Text(
                      'هل هذا المرسل من ${mapping.suggestedBankName}؟',
                      textAlign: TextAlign.center,
                      style: AppTypography.title2(c.textMain),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    _InfoRow(label: 'المرسل', value: mapping.senderId),
                    _InfoRow(label: 'الدولة', value: mapping.suggestedCountry),
                    _InfoRow(label: 'الثقة', value: '$confidence%'),
                    if (mapping.bankKey != null)
                      _InfoRow(label: 'المفتاح', value: mapping.bankKey!),
                    const SizedBox(height: AppSpacing.s3),
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.s3),
                      decoration: BoxDecoration(
                        color: c.surface2.withValues(alpha: isDark ? 0.5 : 0.8),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: c.border),
                      ),
                      child: Text(
                        mapping.reason?.trim().isNotEmpty == true
                            ? 'السبب: ${mapping.reason!.trim()}'
                            : 'السبب: ${mapping.suggestedBankName} يطابق هذا المرسل ونمط الرسائل بدرجة عالية.',
                        style: AppTypography.footnote(c.textLight),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s5),
                    FilledButton(
                      onPressed: _busy ? null : _confirm,
                      child: const Text('تأكيد هذا البنك'),
                    ),
                    const SizedBox(height: AppSpacing.s2),
                    OutlinedButton(
                      onPressed: _busy ? null : _reject,
                      child: const Text('ليس هذا البنك'),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _askLater,
                      child: const Text('اسألني لاحقًا'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: AppTypography.footnote(c.textLight)),
          ),
          Flexible(
            flex: 2,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: AppTypography.bodyStrong(c.textMain),
            ),
          ),
        ],
      ),
    );
  }
}
