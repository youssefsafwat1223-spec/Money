import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/di/app_providers.dart';
import '../common/category_catalog.dart';
import '../../core/theme/widgets/app_toast.dart';

Future<void> exportTransactionsCsv(
  BuildContext context,
  WidgetRef ref,
) async {
  final export = await _buildTransactionsCsv(ref);
  File? file;
  try {
    final directory = await getTemporaryDirectory();
    final timestamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    file = File('${directory.path}/mali-transactions-$timestamp.csv');
    await file.writeAsString(export.csv, flush: true);
    await Share.shareXFiles(
      [
        XFile(
          file.path,
          mimeType: 'text/csv',
          name: 'mali-transactions.csv',
        ),
      ],
      subject: 'Qirsh transactions export',
      text: 'تصدير عمليات قرش بصيغة CSV.',
    );
    if (!context.mounted) return;
    AppToast.show(context, _successMessage(export.count, shared: true));
  } catch (_) {
    // MALI-021: never silently copy the entire ledger to the system
    // clipboard — other apps can read it. Ask first.
    if (!context.mounted) return;
    final copyInstead = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعذّرت المشاركة'),
        content: const Text(
          'هل تريد نسخ بيانات العمليات إلى الحافظة بدلاً من ذلك؟ '
          'انتبه: التطبيقات الأخرى يمكنها قراءة الحافظة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('نسخ إلى الحافظة'),
          ),
        ],
      ),
    );
    if (copyInstead == true) {
      await Clipboard.setData(ClipboardData(text: export.csv));
      if (!context.mounted) return;
      AppToast.show(context, _successMessage(export.count, shared: false));
    }
  } finally {
    // MALI-021: the plaintext CSV must not linger in temp storage after the
    // share sheet closes (share targets copy the file; ours can go).
    try {
      await file?.delete();
    } catch (_) {
      // Best-effort — the OS temp sweep is the backstop.
    }
  }
}

Future<void> exportTransactionsCsvToClipboard(
  BuildContext context,
  WidgetRef ref,
) async {
  final export = await _buildTransactionsCsv(ref);
  await Clipboard.setData(ClipboardData(text: export.csv));
  if (!context.mounted) return;
  AppToast.show(context, _successMessage(export.count, shared: false));
}

Future<_TransactionsCsvExport> _buildTransactionsCsv(WidgetRef ref) async {
  final transactions = await ref.read(transactionRepositoryProvider).getAll();
  final catalog = await ref.read(categoryCatalogProvider.future);
  final buffer = StringBuffer()
    ..writeln(
      'id,occurred_at,amount,currency,type,status,merchant,category,card_last4,balance_after,note',
    );
  for (final tx in transactions) {
    final category = catalog.byId(tx.categoryId);
    buffer.writeln([
      tx.id,
      tx.occurredAt.toUtc().toIso8601String(),
      tx.amount.toStringAsFixed(2),
      tx.currency,
      tx.type.name,
      tx.status.name,
      tx.rawMerchant ?? '',
      category?.nameAr ?? '',
      tx.cardLast4 ?? '',
      tx.balanceAfter?.toStringAsFixed(2) ?? '',
      tx.note ?? '',
    ].map(_csv).join(','));
  }
  return _TransactionsCsvExport(buffer.toString(), transactions.length);
}

String _successMessage(int count, {required bool shared}) {
  if (shared) {
    return count == 0
        ? 'تم تجهيز ملف CSV فارغ للمشاركة.'
        : 'تم تجهيز ملف CSV يحتوي على $count عملية.';
  }
  return count == 0
      ? 'تعذرت المشاركة، وتم نسخ CSV فارغ للحافظة.'
      : 'تعذرت المشاركة، وتم نسخ $count عملية بصيغة CSV للحافظة.';
}

String _csv(String value) {
  final escaped = value.replaceAll('"', '""');
  return '"$escaped"';
}

class _TransactionsCsvExport {
  const _TransactionsCsvExport(this.csv, this.count);

  final String csv;
  final int count;
}
