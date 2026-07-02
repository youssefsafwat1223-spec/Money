import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/id_generator.dart';
import '../../../core/utils/install_id.dart';
import '../../../data/repositories/drift_dedup_store.dart';
import '../../../data/repositories/drift_suspected_duplicate_repository.dart';
import '../../../data/repositories/drift_transaction_repository.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import '../../../domain/entities/suspected_duplicate_entity.dart';
import '../../../domain/entities/transaction_entity.dart';
import 'capture_backend_client.dart';
import 'capture_device_registration_service.dart';

class CaptureSyncResult {
  const CaptureSyncResult({
    required this.importedPayloadIds,
    required this.ackedPayloadIds,
  });

  final Set<String> importedPayloadIds;
  final Set<String> ackedPayloadIds;
}

class CaptureSyncService {
  CaptureSyncService({
    required DriftUserSettingsRepository settingsRepository,
    required DriftTransactionRepository transactionRepository,
    required DriftDedupStore dedupStore,
    required DriftSuspectedDuplicateRepository suspectedDuplicateRepository,
    required CaptureDeviceRegistrationService registrationService,
    CaptureBackendClient? client,
  })  : _settingsRepository = settingsRepository,
        _transactionRepository = transactionRepository,
        _dedupStore = dedupStore,
        _suspectedDuplicateRepository = suspectedDuplicateRepository,
        _registrationService = registrationService,
        _client = client;

  static final DateTime _payloadMarkerTime =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  final DriftUserSettingsRepository _settingsRepository;
  final DriftTransactionRepository _transactionRepository;
  final DriftDedupStore _dedupStore;
  final DriftSuspectedDuplicateRepository _suspectedDuplicateRepository;
  final CaptureDeviceRegistrationService _registrationService;
  final CaptureBackendClient? _client;

  Future<CaptureSyncResult> sync() async {
    final settings = await _settingsRepository.getSettings();
    if (!settings.cloudProcessingEnabled || !SupabaseConfig.isConfigured) {
      return const CaptureSyncResult(
        importedPayloadIds: {},
        ackedPayloadIds: {},
      );
    }

    await _registrationService.syncNativeState();
    final secret = await _registrationService.readDeviceSecret();
    if (secret == null || secret.isEmpty) {
      return const CaptureSyncResult(
        importedPayloadIds: {},
        ackedPayloadIds: {},
      );
    }

    final client = _client ??
        CaptureBackendClient(
          supabaseUrl: SupabaseConfig.url,
          anonKey: SupabaseConfig.anonKey,
        );
    final installId = await InstallId.get();
    final captures = await client.syncCaptures(
      installId: installId,
      deviceSecret: secret,
    );

    final imported = <String>{};
    for (final capture in captures) {
      if (capture.payloadId.isEmpty) continue;
      if (await isPayloadImported(capture.payloadId)) {
        imported.add(capture.payloadId);
        continue;
      }
      await _importCapture(capture);
      imported.add(capture.payloadId);
    }

    if (imported.isNotEmpty) {
      await client.syncCaptures(
        installId: installId,
        deviceSecret: secret,
        ackPayloadIds: imported.toList(),
      );
    }

    return CaptureSyncResult(
      importedPayloadIds: imported,
      ackedPayloadIds: imported,
    );
  }

  Future<bool> isPayloadImported(String payloadId) async {
    final txId = await transactionIdForPayload(payloadId);
    return txId != null;
  }

  Future<String?> transactionIdForPayload(String payloadId) {
    return _dedupStore.transactionIdFor(
      _payloadHash(payloadId),
      _payloadMarkerTime,
    );
  }

  Future<void> _markPayloadImported({
    required String payloadId,
    required String transactionId,
  }) {
    return _dedupStore.mark(
      _payloadHash(payloadId),
      transactionId: transactionId,
      occurredAt: _payloadMarkerTime,
    );
  }

  Future<void> _importCapture(ProcessedCaptureDto capture) async {
    final parsed = capture.parsed;
    var duplicateOf = _string(parsed['possibleDuplicateOfTransactionId']);
    final duplicatePayloadId = _string(parsed['possibleDuplicateOfPayloadId']);
    if (duplicateOf == null && duplicatePayloadId != null) {
      duplicateOf = await _dedupStore.transactionIdFor(
        _payloadHash(duplicatePayloadId),
        _payloadMarkerTime,
      );
    }
    if (capture.status == 'duplicate' && duplicateOf != null) {
      await _suspectedDuplicateRepository.save(
        SuspectedDuplicateEntity(
          id: capture.payloadId,
          rawMessage:
              _string(parsed['rawMessage']) ?? capture.sanitizedText ?? '',
          senderId: _string(parsed['senderId']),
          existingTransactionId: duplicateOf,
          amount: _num(parsed['amount']) ?? 0,
          currency: _string(parsed['currency']) ?? 'SAR',
          rawMerchant: _string(parsed['merchant']),
          occurredAt: _date(parsed['occurredAt']) ??
              capture.createdAt ??
              DateTime.now().toUtc(),
          createdAt: DateTime.now().toUtc(),
          cardLast4: _string(parsed['last4']),
          comparisonTimestamp: _date(parsed['comparisonTimestamp']),
          comparisonTimestampSource:
              _comparisonSource(_string(parsed['comparisonTimestampSource'])),
          duplicateReason: 'backend_suspicious_duplicate',
        ),
      );
      await _markPayloadImported(
        payloadId: capture.payloadId,
        transactionId: duplicateOf,
      );
      return;
    }

    final amount = _num(parsed['amount']);
    final currency = _string(parsed['currency']);
    if (amount == null || currency == null) {
      await _markPayloadImported(
        payloadId: capture.payloadId,
        transactionId: 'rejected:${capture.payloadId}',
      );
      return;
    }

    final now = DateTime.now().toUtc();
    final occurredAt = _date(parsed['occurredAt']) ??
        _date(parsed['comparisonTimestamp']) ??
        capture.createdAt ??
        now;
    final comparisonTimestamp =
        _date(parsed['comparisonTimestamp']) ?? occurredAt;
    final source = _comparisonSource(
      _string(parsed['comparisonTimestampSource']),
    );
    final transaction = TransactionEntity(
      id: IdGenerator.next(),
      amount: amount,
      currency: currency,
      type: _type(_string(parsed['type'])),
      source: TransactionSourceEntity.bank,
      occurredAt: occurredAt,
      rawMessage: _string(parsed['rawMessage']) ??
          capture.sanitizedText ??
          'Backend processed capture ${capture.payloadId}',
      parseConfidence: _num(parsed['confidence']) ?? 0.8,
      status: capture.status == 'needs_review'
          ? TransactionStatus.pending
          : TransactionStatus.confirmed,
      createdAt: now,
      updatedAt: now,
      rawMerchant: _string(parsed['merchant']),
      cardLast4: _string(parsed['last4']),
      direction: _direction(_string(parsed['direction'])),
      transactionTimeFromSms:
          source == ComparisonTimestampSource.smsBody ? occurredAt : null,
      smsReceivedAt: source == ComparisonTimestampSource.receivedAt
          ? comparisonTimestamp
          : null,
      comparisonTimestamp: comparisonTimestamp,
      comparisonTimestampSource: source,
      duplicateStatus:
          _string(parsed['duplicateStatus']) == 'suspicious_duplicate'
              ? DuplicateStatus.suspiciousDuplicate
              : DuplicateStatus.normal,
      possibleDuplicateOfTransactionId:
          _string(parsed['possibleDuplicateOfTransactionId']),
      duplicateReason: _string(parsed['duplicateReason']),
    );
    final saved = await _transactionRepository.saveTransaction(
      transaction: transaction,
      categoryKey: _string(parsed['category']),
    );
    await _markPayloadImported(
      payloadId: capture.payloadId,
      transactionId: saved.id,
    );
  }

  static String _payloadHash(String payloadId) => 'capture_payload:$payloadId';

  static String? _string(Object? value) {
    if (value is! String) return null;
    final clean = value.trim();
    return clean.isEmpty ? null : clean;
  }

  static double? _num(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static DateTime? _date(Object? value) {
    if (value is! String) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  static TransactionTypeEntity _type(String? value) {
    return switch (value) {
      'payment' => TransactionTypeEntity.payment,
      'withdrawal' => TransactionTypeEntity.withdrawal,
      'transfer' => TransactionTypeEntity.transfer,
      'refund' => TransactionTypeEntity.refund,
      'income' => TransactionTypeEntity.income,
      _ => TransactionTypeEntity.unknown,
    };
  }

  static TransactionDirectionEntity _direction(String? value) {
    return switch (value) {
      'credit' => TransactionDirectionEntity.credit,
      'debit' => TransactionDirectionEntity.debit,
      _ => TransactionDirectionEntity.unknown,
    };
  }

  static ComparisonTimestampSource _comparisonSource(String? value) {
    return value == 'sms_body'
        ? ComparisonTimestampSource.smsBody
        : ComparisonTimestampSource.receivedAt;
  }
}
