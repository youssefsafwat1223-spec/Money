// Offline synthetic QA only. Never imported by production lib/.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/features/capture/manual_paste_screen.dart';

const visualParityPasteOutcomeKeys = <String>[
  'manualPasteSaving', 'manualPasteError', 'manualPasteBatchError',
];

final _events = <String, int>{};
Map<String, int> visualParityPasteOutcomeEvents() => Map.unmodifiable(_events);

/// Intercepts before actual ingest implementation or any authority/data action.
/// Never returns a fabricated successful financial/AI result.
class _IngestOutcome implements IngestCapturedMessageUseCase {
  _IngestOutcome(this.key);
  final String key;

  @override
  Future<CapturedMessageResult> fromCapturedMessage(CapturedMessage message, {
    bool onDeviceOnly = false,
    CaptureCommit? capture,
    bool forceLocalAutoConfirm = false,
  }) {
    if (message.source != CapturedMessageSource.manualPaste ||
        onDeviceOnly || capture != null || forceLocalAutoConfirm) {
      throw StateError('paste_outcome_unexpected_authority_or_source');
    }
    _events.update(key, (value) => value + 1, ifAbsent: () => 1);
    if (key == 'manualPasteSaving') return Completer<CapturedMessageResult>().future;
    return Future<CapturedMessageResult>.error(
        StateError('private_synthetic_paste_ingest_failure'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<bool> openVisualParityPasteOutcome(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityPasteOutcomeKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('paste_outcome_requires_offline_debug');
  }
  final rows = await ref.read(appDatabaseProvider).customSelect('PRAGMA database_list').get();
  if (!rows.any((row) => row.read<String>('name') == 'main' && row.read<String>('file').isEmpty)) {
    throw StateError('paste_outcome_requires_memory_database');
  }
  if (!context.mounted) return false;
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
    builder: (_) => ProviderScope(overrides: [
      ingestCapturedMessageUseCaseProvider.overrideWithValue(_IngestOutcome(key)),
    ], child: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(
      builder: (_) => const _PasteHost()))),
  )));
  return true;
}

class _PasteHost extends StatefulWidget {
  const _PasteHost();
  @override
  State<_PasteHost> createState() => _PasteHostState();
}

class _PasteHostState extends State<_PasteHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await ManualPasteScreen.showSheet(context);
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: Text('Synthetic paste outcome host')),
  );
}
