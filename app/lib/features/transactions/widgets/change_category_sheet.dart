import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../domain/entities/budget_entity.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/usecases/correct_category_usecase.dart';
import '../../common/app_sheet_scaffold.dart';
import '../../common/category_catalog.dart';
import '../../common/widgets.dart';
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
    builder: (_) =>
        _ChangeCategorySheet(transaction: transaction, catalog: catalog),
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
            spacing: AppSpacing.s3,
            runSpacing: AppSpacing.s3,
            children: [
              for (final cat in widget.catalog.all.where(
                (it) =>
                    it.key != 'income' &&
                    it.key != BudgetEntity.allExpensesCategoryKey,
              ))
                GestureDetector(
                  onTap: () => setState(() => _selectedKey = cat.key),
                  child: Column(
                    children: [
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          CategoryAvatar(category: cat, size: 52),
                          if (_selectedKey == cat.key)
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: c.primary, width: 2.5),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: 60,
                        child: Text(cat.nameAr,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.caption(c.textLight)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (hasMerchant) ...[
            const SizedBox(height: AppSpacing.s4),
            Text('تطبّق على:', style: AppTypography.subhead(c.textLight)),
            RadioListTile<CategoryCorrectionScope>(
              value: CategoryCorrectionScope.thisTransactionOnly,
              groupValue: _scope,
              onChanged: (v) => setState(() => _scope = v!),
              contentPadding: EdgeInsets.zero,
              title: Text('هذه العملية فقط',
                  style: AppTypography.body(c.textMain)),
              activeColor: c.primary,
            ),
            RadioListTile<CategoryCorrectionScope>(
              value: CategoryCorrectionScope.allMerchantTransactions,
              groupValue: _scope,
              onChanged: (v) => setState(() => _scope = v!),
              contentPadding: EdgeInsets.zero,
              title: Text('كل عمليات هذا المتجر',
                  style: AppTypography.body(c.textMain)),
              activeColor: c.primary,
            ),
          ],
          const SizedBox(height: AppSpacing.s4),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(
                backgroundColor: c.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: Text('حفظ', style: AppTypography.bodyStrong(Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}
