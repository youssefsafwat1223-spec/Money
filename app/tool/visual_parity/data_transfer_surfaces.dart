// Offline picker-transport fixtures. Never imported by lib/.
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
// The pinned 11.0.3 package does not export its platform interface publicly.
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/data_portability/app_data_portability_service.dart';
import 'package:money_companion/core/data_portability/portable_csv.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/settings/data_transfer_screen.dart';

const visualParityDataTransferSurfaceKeys = [
  'dataTransferImportPreview',
  'dataTransferBadFile',
  'dataTransferReading',
  'dataTransferInvalidPreview',
  'dataTransferDuplicatePolicy',
  'dataTransferImportResult',
  'dataTransferGuestReplace',
];

_PickerLease? _activeLease;

class _PickerLease extends FilePickerPlatform {
  _PickerLease(this.key, this.onEvent) : previous = FilePickerPlatform.instance;
  final String key;
  final void Function(String)? onEvent;
  final FilePickerPlatform previous;
  final pending = Completer<FilePickerResult?>();
  Directory? directory;
  File? file;
  AppDatabase? ownedDatabase;
  Future<void>? _closing;

  @override
  Future<FilePickerResult?> pickFiles(
      {String? dialogTitle,
      String? initialDirectory,
      FileType type = FileType.any,
      List<String>? allowedExtensions,
      Function(FilePickerStatus)? onFileLoading,
      int compressionQuality = 0,
      bool allowMultiple = false,
      bool withData = false,
      bool withReadStream = false,
      bool lockParentWindow = false,
      bool readSequential = false,
      bool cancelUploadOnWindowBlur = true}) async {
    if (type != FileType.custom ||
        !listEquals(allowedExtensions, ['csv', 'zip']) ||
        allowMultiple ||
        withData ||
        withReadStream) {
      throw StateError('transfer_visual_unexpected_picker_request');
    }
    onEvent?.call('${key}PickerRequested');
    if (key == 'dataTransferReading') return pending.future;
    final selected = file!;
    return FilePickerResult([
      PlatformFile(
          path: selected.path,
          name: selected.uri.pathSegments.last,
          size: await selected.length())
    ]);
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    // Restore immediately, before asynchronous cleanup or route transitions.
    FilePickerPlatform.instance = previous;
    if (identical(_activeLease, this)) _activeLease = null;
    if (!pending.isCompleted) pending.complete(null);
    final ownDirectory = directory;
    if (ownDirectory != null && await ownDirectory.exists()) {
      await ownDirectory.delete(recursive: true);
    }
    await ownedDatabase?.close();
    onEvent?.call('${key}Closed');
  }
}

class _TransferLifetime extends StatefulWidget {
  const _TransferLifetime(this.lease, this.child);
  final _PickerLease lease;
  final Widget child;
  @override
  State<_TransferLifetime> createState() => _TransferLifetimeState();
}

class _TransferLifetimeState extends State<_TransferLifetime> {
  @override
  void dispose() {
    unawaited(widget.lease.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<bool> openVisualParityDataTransferSurface(
    BuildContext context, WidgetRef ref, String key,
    {void Function(String)? onEvent}) async {
  if (!visualParityDataTransferSurfaceKeys.contains(key)) {
    return false;
  }
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('transfer_visual_requires_offline_debug');
  }
  // The lease is process-global because FilePicker's actual API is static.
  if (_activeLease != null) {
    throw StateError('transfer_visual_picker_already_leased');
  }
  final lease = _PickerLease(key, onEvent);
  _activeLease = lease;
  try {
    final db = ref.read(appDatabaseProvider);
    final databases = await db.customSelect('PRAGMA database_list').get();
    if (!databases.any((row) =>
        row.read<String>('name') == 'main' &&
        row.read<String>('file').isEmpty)) {
      throw StateError('transfer_visual_requires_memory_database');
    }
    if (!context.mounted) {
      await lease.close();
      return false;
    }
    final owned = visualParityDataTransferSurfaceKeys.indexOf(key) >= 3;
    final target = owned
        ? await AppDatabase.open(
            executor: NativeDatabase.memory(),
            keyStore: _FixtureKeys(),
            initialLanguage: 'en')
        : db;
    if (owned) lease.ownedDatabase = target;
    final accounts = DriftAccountRepository(target);
    final transactions = DriftTransactionRepository(target);
    if (owned) {
      final now = DateTime.utc(2026, 10, 10, 12);
      await accounts.create(AccountEntity(
          id: 'qa-transfer-account',
          name: 'QA isolated EGP account',
          currency: 'EGP',
          type: AccountType.bank,
          initialBalanceMoney: Money.zero('EGP'),
          currentBalanceMoney: Money.zero('EGP'),
          isDefault: true,
          sortOrder: 0,
          createdAt: now,
          updatedAt: now));
      if (key == 'dataTransferDuplicatePolicy' ||
          key == 'dataTransferImportResult') {
        await transactions.saveTransaction(
            transaction: TransactionEntity(
                id: 'qa-transfer-existing-payment',
                amountMoney: Money(7525, 'EGP'),
                currency: 'EGP',
                accountId: 'qa-transfer-account',
                rawMerchant: 'QA duplicate market',
                type: TransactionTypeEntity.payment,
                source: TransactionSourceEntity.bank,
                occurredAt: now,
                comparisonTimestamp: now,
                rawMessage: 'Synthetic duplicate fixture',
                parseConfidence: 1,
                direction: TransactionDirectionEntity.debit,
                status: TransactionStatus.confirmed,
                createdAt: now,
                updatedAt: now),
            categoryKey: null);
      }
    }
    final service = AppDataPortabilityService(
        db: target,
        accounts: accounts,
        categories: DriftCategoryRepository(target),
        transactions: transactions,
        settings: DriftUserSettingsRepository(target),
        // This database was allocated here with no persisted owner or session.
        // Only the package preview reads this local guest property.
        isCloudOwned: () async => key == 'dataTransferGuestReplace'
            ? false
            : throw StateError('transfer_visual_no_authority_request'));
    if (key != 'dataTransferReading') {
      lease.directory =
          await Directory.systemTemp.createTemp('qirsh-visual-transfer-');
      final package = key == 'dataTransferGuestReplace';
      lease.file =
          File('${lease.directory!.path}/qirsh-qa.${package ? 'zip' : 'csv'}');
      if (package) {
        // Actual local exporter returns bytes only; no share/native export flow.
        await lease.file!
            .writeAsBytes((await service.exportFinancialPackage()).bytes);
      } else {
        final bytes = switch (key) {
          'dataTransferBadFile' => encodePortableCsv([
              'date',
              'date'
            ], [
              ['2026-10-10', '125.50']
            ]),
          'dataTransferInvalidPreview' => encodePortableCsv([
              'unmapped'
            ], [
              ['one column']
            ]),
          'dataTransferDuplicatePolicy' => encodePortableCsv([
              'date',
              'amount',
              'currency',
              'merchant'
            ], [
              ['2026-10-10T12:00:00Z', -75.25, 'EGP', 'QA duplicate market']
            ]),
          'dataTransferImportResult' => encodePortableCsv([
              'date',
              'amount',
              'currency',
              'merchant'
            ], [
              [
                '2026-10-10T13:00:00Z',
                -125.50,
                'EGP',
                'QA newly imported market'
              ],
              ['2026-10-10T12:00:00Z', -75.25, 'EGP', 'QA duplicate market'],
              ['2026-10-10T14:00:00Z', 'invalid', 'EGP', 'QA rejected amount']
            ]),
          _ => encodePortableCsv([
              'date',
              'amount',
              'currency',
              'merchant',
              'note'
            ], [
              [
                '2026-10-10',
                '125.50',
                'EGP',
                'QA preview market',
                'Preview only'
              ]
            ]),
        };
        await lease.file!.writeAsBytes(bytes);
      }
    }
    if (!context.mounted) {
      await lease.close();
      return false;
    }
    FilePickerPlatform.instance = lease;
    unawaited(Navigator.of(context)
        .push<void>(MaterialPageRoute<void>(
          builder: (_) => _TransferLifetime(
              lease,
              ProviderScope(overrides: [
                dataPortabilityServiceProvider.overrideWithValue(service),
                if (owned) ...[
                  appDatabaseProvider.overrideWithValue(target),
                  accountRepositoryProvider.overrideWithValue(accounts),
                  accountsProvider.overrideWith((ref) => accounts.getAll()),
                ],
              ], child: const DataTransferScreen(initialAction: 'import'))),
        ))
        .whenComplete(lease.close));
    return true;
  } catch (_) {
    await lease.close();
    rethrow;
  }
}

// Never touches Keychain. The executor passed with this key is always memory.
class _FixtureKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'visual-transfer-isolated-memory';
  @override
  Future<String?> readStoredKey() async => 'visual-transfer-isolated-memory';
}
