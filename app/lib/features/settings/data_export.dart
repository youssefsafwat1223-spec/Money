import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/di/app_providers.dart';
import '../common/category_catalog.dart';

Future<void> exportTransactionsCsv(
  BuildContext context,
  WidgetRef ref,
) async {
  final export = await _buildTransactionsCsv(ref);
  try {
    final directory = await getTemporaryDirectory();
    final timestamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final file = File('${directory.path}/mali-transactions-$timestamp.csv');
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_successMessage(export.count, shared: true))),
    );
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: export.csv));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_successMessage(export.count, shared: false))),
    );
  }
}

Future<void> exportTransactionsCsvToClipboard(
  BuildContext context,
  WidgetRef ref,
) async {
  final export = await _buildTransactionsCsv(ref);
  await Clipboard.setData(ClipboardData(text: export.csv));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(_successMessage(export.count, shared: false))),
  );
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
