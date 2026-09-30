import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../domain/entities/sender_bank_mapping_entity.dart';
import 'bank_discovery_controller.dart';
import '../../core/utils/l10n_ext.dart';

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
      await ref.read(senderBankMappingSyncServiceProvider)?.push();
    });
  }

  Future<void> _reject() async {
    await _run(() async {
      await _controller.reject(widget.mapping);
      await ref.read(senderBankMappingSyncServiceProvider)?.push();
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
      textDirection: Directionality.of(context),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: MaliGlass(
          variant: MaliGlassVariant.sheet,
          child: Material(
            color: Colors.transparent,
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
                      context.l10n.bdConfirmTitle,
                      textAlign: TextAlign.center,
                      style: AppTypography.subhead(c.textLight),
                    ),
                    const SizedBox(height: AppSpacing.s2),
                    Text(
                      context.l10n.bdIsSenderFrom(mapping.suggestedBankName),
                      textAlign: TextAlign.center,
                      style: AppTypography.title2(c.textMain),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    _InfoRow(label: context.l10n.bdSender, value: mapping.senderId),
                    _InfoRow(
                        label: context.l10n.bdCountry,
                        value: mapping.suggestedCountry),
                    _InfoRow(
                        label: context.l10n.bdConfidence,
                        value: '$confidence%'),
                    if (mapping.bankKey != null)
                      _InfoRow(
                          label: context.l10n.bdKey,
                          value: mapping.bankKey!),
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
                            ? context.l10n.bdReason(mapping.reason!.trim())
                            : context.l10n
                                .bdReasonDefault(mapping.suggestedBankName),
                        style: AppTypography.footnote(c.textLight),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s5),
                    FilledButton(
                      onPressed: _busy ? null : _confirm,
                      child: Text(context.l10n.bdConfirmThis),
                    ),
                    const SizedBox(height: AppSpacing.s2),
                    OutlinedButton(
                      onPressed: _busy ? null : _reject,
                      child: Text(context.l10n.bdNotThis),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _askLater,
                      child: Text(context.l10n.bdAskLater),
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
