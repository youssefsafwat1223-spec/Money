import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../engine/categorization/categorizer.dart';
import '../../engine/categorization/category.dart';
import '../../engine/parser/parser_engine.dart';

/// شاشة تأسيس (smoke test): تثبت أن الـ theme + RTL + الخطوط + الأيقونات +
/// المحرك تعمل معاً. ليست شاشة منتج — Codex يستبدلها بالـ onboarding/dashboard.
class FoundationHomeScreen extends ConsumerStatefulWidget {
  const FoundationHomeScreen({super.key});

  @override
  ConsumerState<FoundationHomeScreen> createState() =>
      _FoundationHomeScreenState();
}

class _FoundationHomeScreenState extends ConsumerState<FoundationHomeScreen> {
  static const _sample = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
      'لدى:BURGER BOUTIQUE\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';

  final _controller = TextEditingController(text: _sample);
  String _output = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _run() {
    final result = const ParserEngine().parse(_controller.text);
    if (!result.isTransaction) {
      setState(() => _output = 'ليست معاملة مالية — تُتجاهَل.');
      return;
    }
    final txn = result.transaction!;
    final cat = Categorizer().categorize(txn);
    setState(() {
      _output = 'المبلغ: ${txn.amount} ${txn.currency}\n'
          'المتجر: ${txn.rawMerchant ?? '-'}\n'
          'النوع: ${txn.type.name}\n'
          'البطاقة: ${txn.cardLast4 ?? '-'}\n'
          'التاريخ: ${txn.occurredAt ?? '-'}\n'
          'الرصيد: ${txn.balanceAfter ?? '-'}\n'
          'التصنيف: ${Categories.byKey(cat.categoryKey).arName}\n'
          'الثقة: ${txn.parseConfidence.toStringAsFixed(2)}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: ListView(
            children: [
              Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      gradient: c.primaryGradient,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: const Icon(
                      AppLucideIcons.walletCards,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Text('رفيقك المالي — الأساس',
                        style: AppTypography.title2(c.textMain)),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s5),
              Text('جرّب المحرّك على رسالة',
                  style: AppTypography.subhead(c.textLight)),
              const SizedBox(height: AppSpacing.s2),
              TextField(
                controller: _controller,
                maxLines: 5,
                style: AppTypography.body(c.textMain),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: c.surface2,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide(color: c.border),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.s3),
              SizedBox(
                height: 56,
                child: FilledButton(
                  onPressed: _run,
                  style: FilledButton.styleFrom(
                    backgroundColor: c.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  child: Text('حلّل',
                      style: AppTypography.bodyStrong(Colors.white)),
                ),
              ),
              const SizedBox(height: AppSpacing.s5),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.s4),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  border: Border.all(color: c.border),
                ),
                child: Text(_output, style: AppTypography.body(c.textMain)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
