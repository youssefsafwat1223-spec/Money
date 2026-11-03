// Offline presentation QA. Every simulated write holds/fails before mutation.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/domain/entities/sender_bank_mapping_entity.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';
import 'package:money_companion/features/bank_discovery/bank_discovery_confirmation_sheet.dart';

const visualParityBankDiscoveryOutcomeKeys = <String>[
  'bankDiscoveryConfirmSaving',
  'bankDiscoveryConfirmError',
  'bankDiscoveryRejectSaving',
  'bankDiscoveryRejectError',
];
final _events = <String, int>{};
Map<String, int> visualParityBankDiscoveryOutcomeEvents() =>
    Map.unmodifiable(_events);

const _mappingId = 'qa-bank-discovery-outcome-proposal';

class _MappingOutcome implements SenderBankMappingRepository {
  _MappingOutcome(this.key);
  final String key;
  Future<SenderBankMappingEntity> _outcome(String operation, String id) {
    if (id != _mappingId || !key.contains(operation)) {
      throw StateError('bank_outcome_unexpected_proposal_or_operation');
    }
    _events.update(key, (count) => count + 1, ifAbsent: () => 1);
    if (key.endsWith('Saving')) {
      return Completer<SenderBankMappingEntity>().future;
    }
    return Future<SenderBankMappingEntity>.error(
        StateError('private_bank_outcome_failure'));
  }

  @override
  Future<SenderBankMappingEntity> confirm(
      {required String mappingId, String? bankKey, DateTime? now}) {
    if (bankKey != 'qa_bank') throw StateError('bank_outcome_unexpected_bank');
    return _outcome('Confirm', mappingId);
  }

  @override
  Future<SenderBankMappingEntity> reject(
      {required String mappingId, required Duration cooldown, DateTime? now}) {
    if (cooldown != const Duration(days: 30)) {
      throw StateError('bank_outcome_unexpected_cooldown');
    }
    return _outcome('Reject', mappingId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('bank_outcome_operation_forbidden');
}

Future<bool> openVisualParityBankDiscoveryOutcome(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityBankDiscoveryOutcomeKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('bank_outcome_requires_offline_debug');
  }
  final databases = await ref
      .read(appDatabaseProvider)
      .customSelect('PRAGMA database_list')
      .get();
  if (!databases.any((row) =>
      row.read<String>('name') == 'main' && row.read<String>('file').isEmpty)) {
    throw StateError('bank_outcome_requires_memory_database');
  }
  if (!context.mounted) return false;
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
    builder: (_) => ProviderScope(
        overrides: [
          senderBankMappingRepositoryProvider
              .overrideWithValue(_MappingOutcome(key)),
          senderBankMappingSyncServiceProvider.overrideWithValue(null),
        ],
        child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => const _BankOutcomeHost()))),
  )));
  return true;
}

class _BankOutcomeHost extends StatefulWidget {
  const _BankOutcomeHost();
  @override
  State<_BankOutcomeHost> createState() => _BankOutcomeHostState();
}

class _BankOutcomeHostState extends State<_BankOutcomeHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final now = DateTime.utc(2026, 6, 16);
      // Plain pending presentation value only, never persisted or accepted.
      await showBankDiscoveryConfirmationSheet(
          context,
          SenderBankMappingEntity(
              id: _mappingId,
              senderId: 'QA BANK',
              normalizedSenderId: 'QA BANK',
              bankKey: 'qa_bank',
              suggestedBankName: 'QA Bank',
              suggestedCountry: 'EG',
              confidence: .97,
              reason: null,
              status: SenderBankMappingStatus.pending,
              source: SenderBankMappingSource.gemini,
              firstSeenAt: now,
              lastSeenAt: now,
              createdAt: now,
              updatedAt: now,
              confirmedAt: null,
              rejectedAt: null,
              rejectionExpiresAt: null,
              syncedAt: null,
              syncStatus: SenderBankMappingSyncStatus.pending));
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}
