import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/widgets/navy_sheet_theme.dart';
import '../../../domain/entities/budget_entity.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/usecases/correct_category_usecase.dart';
import '../../common/app_sheet_scaffold.dart';
import '../../common/app_category_chip.dart';
import '../../common/app_button.dart';
import '../../common/category_catalog.dart';
import '../../dashboard/dashboard_providers.dart';
import '../transactions_providers.dart';

Future<void> showChangeCategorySheet(
  BuildContext context,
  TransactionEntity transaction,
  CategoryCatalog catalog,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => navySheetTheme(
        _ChangeCategorySheet(transaction: transaction, catalog: catalog)),
  );
}

class _ChangeCategorySheet extends ConsumerStatefulWidget {
  const _ChangeCategorySheet(
      {required this.transaction, required this.catalog});

  final TransactionEntity transaction;
  final CategoryCatalog catalog;

  @override
  ConsumerState<_ChangeCategorySheet> createState() => _State();
}

class _State extends ConsumerState<_ChangeCategorySheet> {
  String? _selectedKey;
  CategoryCorrectionScope _scope = CategoryCorrectionScope.thisTransactionOnly;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedKey = widget.catalog.byId(widget.transaction.categoryId)?.key;
  }

  Future<void> _save() async {
    if (_selectedKey == null || _saving) return;
    setState(() => _saving = true);
    await ref.read(correctCategoryUseCaseProvider)(
      transactionId: widget.transaction.id,
      categoryKey: _selectedKey!,
      scope: _scope,
    );
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasMerchant = widget.transaction.rawMerchant != null;

    return AppSheetScaffold(
      title: 'غيّر التصنيف',
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            children: [
              for (final cat in widget.catalog.all.where(
                (it) =>
                    it.key != 'income' &&
                    it.key != BudgetEntity.allExpensesCategoryKey,
              ))
                AppCategoryChip(
                  label: cat.nameAr,
                  icon: cat.icon,
                  color: _selectedKey == cat.key ? c.primary : c.textLight,
                  selected: _selectedKey == cat.key,
                  onTap: () => setState(() => _selectedKey = cat.key),
                ),
            ],
          ),
          if (hasMerchant) ...[
            const SizedBox(height: AppSpacing.s5),
            Text('نطاق التعديل', style: AppTypography.caption(c.textLight)),
            const SizedBox(height: AppSpacing.s2),
            Material(
              color: c.surface2.withValues(alpha: 0.5),
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: c.border),
              ),
              child: Column(
                children: [
                  RadioListTile<CategoryCorrectionScope>(
                    value: CategoryCorrectionScope.thisTransactionOnly,
                    groupValue: _scope,
                    onChanged: (v) => setState(() => _scope = v!),
                    title: Text('هذه العملية فقط',
                        style: AppTypography.body(c.textMain)),
                    activeColor: c.primary,
                  ),
                  Divider(height: 1, color: c.border),
                  RadioListTile<CategoryCorrectionScope>(
                    value: CategoryCorrectionScope.allMerchantTransactions,
                    groupValue: _scope,
                    onChanged: (v) => setState(() => _scope = v!),
                    title: Text('كل عمليات هذا المتجر',
                        style: AppTypography.body(c.textMain)),
                    activeColor: c.primary,
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.s5),
          AppButton(
            label: 'حفظ التعديل',
            onPressed: _saving ? null : _save,
            isPrimary: true,
          ),
        ],
      ),
    );
  }
}
