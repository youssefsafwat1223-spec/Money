import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/install_id.dart';
import '../../../data/repositories/drift_dedup_store.dart';
import '../../../data/repositories/drift_suspected_duplicate_repository.dart';
import '../../../data/repositories/drift_transaction_repository.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import '../../../domain/entities/account_entity.dart';
import '../../../domain/entities/suspected_duplicate_entity.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/repositories/account_repository.dart';
import '../../../domain/usecases/add_transaction_usecase.dart';
import '../../../engine/privacy/sms_sanitizer.dart';
import '../../../engine/parser/capture_money.dart';
import 'capture_backend_client.dart';
import 'capture_device_registration_service.dart';
import 'native_capture_bridge.dart';

class CaptureSyncResult {
  const CaptureSyncResult({
    required this.importedPayloadIds,
    required this.ackedPayloadIds,
    required this.needsReviewTransactionIds,
  });

  final Set<String> importedPayloadIds;
  final Set<String> ackedPayloadIds;
  final List<String> needsReviewTransactionIds;
}

class CaptureSyncService {
  CaptureSyncService({
    required DriftUserSettingsRepository settingsRepository,
    required DriftTransactionRepository transactionRepository,
    required DriftDedupStore dedupStore,
    required DriftSuspectedDuplicateRepository suspectedDuplicateRepository,
    required CaptureDeviceRegistrationService registrationService,
    AccountRepository? accountRepository,
    CaptureBackendClient? client,
    bool? backendConfigured,
    Future<String> Function()? loadInstallId,
    // MALI-026 (B8-2.10 §12): the money-authority mode. Defaults to legacy, so
    // v29 capture ingestion is unchanged; only canonical mode makes a
    // numeric-only (no exact amount_text) capture unconditionally pending.
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
  })  : _settingsRepository = settingsRepository,
        _transactionRepository = transactionRepository,
        _dedupStore = dedupStore,
        _suspectedDuplicateRepository = suspectedDuplicateRepository,
        _registrationService = registrationService,
        _accountRepository = accountRepository,
        _client = client,
        _backendConfigured = backendConfigured,
        _loadInstallId = loadInstallId,
        _coordinator = coordinator;

  static final DateTime _payloadMarkerTime =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  final DriftUserSettingsRepository _settingsRepository;
  final DriftTransactionRepository _transactionRepository;
  final DriftDedupStore _dedupStore;
  final DriftSuspectedDuplicateRepository _suspectedDuplicateRepository;
  final CaptureDeviceRegistrationService _registrationService;
  final AccountRepository? _accountRepository;
  final CaptureBackendClient? _client;
  final bool? _backendConfigured;
  final Future<String> Function()? _loadInstallId;
  final PlanningCutoverCoordinator _coordinator;

  // مزامنة واحدة في الرحلة الواحدة: الاستئناف (resume) وضغطة الإشعار يصلان
  // في نفس اللحظة تقريبًا، وبدون هذا القفل يجلب الاثنان نفس صفوف الـ relay
  // قبل أن يُسجَّل أيّ منهما كمستورد — فتُستورد العملية مرّتين.
  Future<CaptureSyncResult>? _inFlightSync;

  // MALI-029 (pull batching) — a currency→account map prefetched ONCE per sync
  // run instead of reloading the whole accounts table for every captured row
  // (`getAll()` was O(captures) full-table scans). Populated at the start of
  // _syncOnce and cleared when it finishes; sync() is single-flight, so there is
  // no concurrent run to share it. First-match-per-currency mirrors the previous
  // linear-scan behavior; a create-on-miss updates the map so later rows in the
  // same batch reuse the new account.
  Map<String, AccountEntity>? _currencyAccountCache;
  // Running total of accounts during a sync run, so a create-on-miss keeps the
  // exact isDefault (`total == 0`) and sortOrder (`total`) the per-row getAll()
  // path produced.
  int _currencyAccountTotal = 0;

  Future<CaptureSyncResult> sync() {
    final pending = _inFlightSync;
    if (pending != null) return pending;
    final run = _syncOnce().whenComplete(() {
      _inFlightSync = null;
      _currencyAccountCache = null;
    });
    _inFlightSync = run;
    return run;
  }

  Future<CaptureSyncResult> _syncOnce() async {
    final settings = await _settingsRepository.getSettings();
    final backendConfigured = _backendConfigured ?? SupabaseConfig.isConfigured;
    if (!settings.cloudProcessingEnabled || !backendConfigured) {
      return const CaptureSyncResult(
        importedPayloadIds: {},
        ackedPayloadIds: {},
        needsReviewTransactionIds: [],
      );
    }

    await _registrationService.syncBackendState();
    final secret = await _registrationService.readDeviceSecret();
    if (secret == null || secret.isEmpty) {
      return const CaptureSyncResult(
        importedPayloadIds: {},
        ackedPayloadIds: {},
        needsReviewTransactionIds: [],
      );
    }

    final client = _client ??
        CaptureBackendClient(
          supabaseUrl: SupabaseConfig.url,
          anonKey: SupabaseConfig.anonKey,
        );
    final installId = await (_loadInstallId ?? InstallId.get)();
    final captures = await client.syncCaptures(
      installId: installId,
      deviceSecret: secret,
    );

    // MALI-029 — prefetch accounts once (first-match-per-currency), reused for
    // every capture in this batch instead of a full accounts reload per row.
    _currencyAccountCache = await _buildCurrencyAccountCache();

    final imported = <String>{};
    final needsReviewTransactionIds = <String>[];
    for (final capture in captures) {
      if (capture.payloadId.isEmpty) continue;
      if (await isPayloadImported(capture.payloadId)) {
        imported.add(capture.payloadId);
        continue;
      }
      final needsReviewTransactionId = await _importCapture(capture);
      if (needsReviewTransactionId != null) {
        needsReviewTransactionIds.add(needsReviewTransactionId);
      }
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
      needsReviewTransactionIds: needsReviewTransactionIds,
    );
  }

  Future<bool> isPayloadImported(String payloadId) async {
    final txId = await transactionIdForPayload(payloadId);
    return txId != null;
  }

  /// Retries a native payload whose extension may have been killed in-flight.
  /// False means cloud retry is disabled, so the caller may use local fallback.
  Future<bool> retryPendingSend(SharedCapturedMessage message) async {
    if (message.status != 'pendingSend' || message.id == null) return false;
    final settings = await _settingsRepository.getSettings();
    final configured = _backendConfigured ?? SupabaseConfig.isConfigured;
    if (!settings.cloudProcessingEnabled || !configured) return false;
    final secret = await _registrationService.readDeviceSecret();
    if (secret == null || secret.isEmpty) return false;
    final client = _client ??
        CaptureBackendClient(
          supabaseUrl: SupabaseConfig.url,
          anonKey: SupabaseConfig.anonKey,
        );
    await client.processIosSms(
      installId: await (_loadInstallId ?? InstallId.get)(),
      deviceSecret: secret,
      payloadId: message.id!,
      // The server persists this value verbatim (processed_captures.parsed.
      // rawMessage) for every message regardless of outcome, so it must never
      // carry card/phone/account numbers or third-party beneficiary names —
      // sanitize on-device first, same discipline as SmsSanitizer's other
      // call sites (add_transaction_usecase.dart, bank_discovery_service.dart).
      smsText: SmsSanitizer.sanitize(message.text),
      sender: message.sender,
      receivedAt: message.receivedAt ?? DateTime.now().toUtc(),
      locale: message.locale,
      allowAi: settings.aiConsentGranted,
    );
    return true;
  }

  Future<String?> transactionIdForPayload(String payloadId) {
    return _dedupStore.transactionIdFor(
      _payloadHash(payloadId),
      _payloadMarkerTime,
    );
  }

  /// Public so the native-queue drain can flag a payload it imported first;
  /// the next backend sync then skips (and acks) the same capture instead of
  /// importing it a second time.
  Future<void> markPayloadImported({
    required String payloadId,
    required String transactionId,
  }) {
    return _dedupStore.mark(
      _payloadHash(payloadId),
      transactionId: transactionId,
      occurredAt: _payloadMarkerTime,
    );
  }

  Future<String?> _importCapture(ProcessedCaptureDto capture) async {
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
      final duplicateCurrency =
          (_string(parsed['currency']) ?? 'SAR').trim().toUpperCase();
      final duplicateAmountText = _string(parsed['amount_text']);
      final duplicateNumericAmount = _num(parsed['amount']);
      late final Money duplicateAmountMoney;
      if (duplicateAmountText != null) {
        try {
          duplicateAmountMoney =
              parseCaptureMoney(duplicateAmountText, duplicateCurrency);
        } on Exception {
          // LEGACY_LOSSY compatibility for an already-decoded duplicate DTO.
          duplicateAmountMoney = legacyLossyNumberToMoney(
            duplicateNumericAmount ?? 0,
            duplicateCurrency,
          );
        }
      } else {
        // LEGACY_LOSSY compatibility for an old duplicate DTO without text.
        duplicateAmountMoney = legacyLossyNumberToMoney(
          duplicateNumericAmount ?? 0,
          duplicateCurrency,
        );
      }
      await _suspectedDuplicateRepository.save(
        SuspectedDuplicateEntity(
          id: capture.payloadId,
          rawMessage:
              _string(parsed['rawMessage']) ?? capture.sanitizedText ?? '',
          senderId: _string(parsed['senderId']),
          existingTransactionId: duplicateOf,
          amountMoney: duplicateAmountMoney,
          currency: duplicateCurrency,
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
      await markPayloadImported(
        payloadId: capture.payloadId,
        transactionId: duplicateOf,
      );
      return null;
    }

    final amount = _num(parsed['amount']);
    final amountText = _string(parsed['amount_text']);
    final currency = _string(parsed['currency']);
    if ((amount == null && amountText == null) || currency == null) {
      await markPayloadImported(
        payloadId: capture.payloadId,
        transactionId: 'rejected:${capture.payloadId}',
      );
      return null;
    }

    final now = DateTime.now().toUtc();
    final normalizedCurrency = currency.trim().toUpperCase();
    late final Money amountMoney;
    var legacyLossyReview = false;
    if (amountText != null) {
      try {
        amountMoney = parseCaptureMoney(amountText, normalizedCurrency);
      } on Exception {
        if (amount == null) {
          await markPayloadImported(
              payloadId: capture.payloadId,
              transactionId: 'rejected:${capture.payloadId}');
          return null;
        }
        // LEGACY_LOSSY capture fallback (pending review).
        amountMoney = legacyLossyNumberToMoney(amount, normalizedCurrency);
        legacyLossyReview = true;
      }
    } else {
      // LEGACY_LOSSY deployed-backend compatibility: no amount_text yet.
      amountMoney = legacyLossyNumberToMoney(amount!, normalizedCurrency);
      legacyLossyReview = true;
    }
    // MALI-026 (B8-2.10 §12/§13): route ingestion through the explicit ingress
    // resolver. In canonical mode a numeric-only / non-exact capture can NEVER
    // auto-confirm into canonical authority — it is forced to pending review.
    // Legacy (v29) is unchanged: exact text confirms, numeric-only reviews.
    final requiresReview = resolveAiCaptureIngress(
          hasExactText: !legacyLossyReview,
          canonicalMode: _coordinator.state() == PlanningCutoverState.canonical,
        ) ==
        AiCaptureIngress.legacyPendingReview;
    final account = await _accountForCurrency(normalizedCurrency);
    final occurredAt = _date(parsed['occurredAt']) ??
        _date(parsed['comparisonTimestamp']) ??
        capture.createdAt ??
        now;
    final comparisonTimestamp =
        _date(parsed['comparisonTimestamp']) ?? occurredAt;
    final source = _comparisonSource(
      _string(parsed['comparisonTimestampSource']),
    );
    final rawMessage = _string(parsed['rawMessage']) ??
        capture.sanitizedText ??
        'Backend processed capture ${capture.payloadId}';
    final direction = _direction(_string(parsed['direction']));
    var type = _type(_string(parsed['type']));
    // نفس محاسبة التحويلات في AddTransactionUseCase: النقل بين حساباتك محايد،
    // أما الصادر لخارجها فمصروف والوارد دخل — وإلا تُستبعد من الإجماليات خطأً.
    if (type == TransactionTypeEntity.transfer &&
        !AddTransactionUseCase.looksLikeInternalTransfer(rawMessage)) {
      if (direction == TransactionDirectionEntity.debit) {
        type = TransactionTypeEntity.payment;
      } else if (direction == TransactionDirectionEntity.credit) {
        type = TransactionTypeEntity.income;
      }
    }
    final transaction = TransactionEntity(
      // The payload id IS the transaction's identity. The outbox push uses the
      // local id as client_request_id, and the server's direct-write (Phase 5)
      // stores the same payloadId there — so this import's push UPDATES the
      // server row the edge function already wrote instead of duplicating it.
      // isPayloadImported() above guarantees this id is never inserted twice.
      id: capture.payloadId,
      amountMoney: amountMoney,
      currency: normalizedCurrency,
      accountId: account?.id,
      type: type,
      source: _string(parsed['parserSource']) == 'ai_hybrid'
          ? TransactionSourceEntity.aiParsed
          : TransactionSourceEntity.bank,
      occurredAt: occurredAt,
      rawMessage: rawMessage,
      parseConfidence: _num(parsed['confidence']) ?? 0.8,
      // capture بحالة duplicate تصل هنا فقط عندما تعذّر ربطها بعمليتها
      // الأصلية محليًا (سجل الربط فُقد أو الأصل على جهاز آخر) — لا تُعتمد
      // أبدًا كمؤكَّدة، وإلا حُسب المبلغ مرّتين بصمت رغم إشعار "مشابهة".
      status: requiresReview ||
              capture.status == 'needs_review' ||
              capture.status == 'duplicate'
          ? TransactionStatus.pending
          : TransactionStatus.confirmed,
      createdAt: now,
      updatedAt: now,
      rawMerchant: _string(parsed['merchant']),
      cardLast4: _string(parsed['last4']),
      direction: direction,
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
    // Atomic import (MALI-012): transaction row (+outbox, via the repo's own
    // transaction → savepoint) and the payload dedup marker commit or roll back
    // together — a kill between them can no longer leave an imported row whose
    // payload re-imports as a duplicate, nor a marked payload whose transaction
    // never landed.
    final saved = await _dedupStore.runAtomically(() async {
      final inserted = await _transactionRepository.saveTransaction(
        transaction: transaction,
        categoryKey: _string(parsed['category']),
      );
      await markPayloadImported(
        payloadId: capture.payloadId,
        transactionId: inserted.id,
      );
      return inserted;
    });
    return legacyLossyReview ||
            capture.status == 'needs_review' ||
            capture.status == 'duplicate'
        ? saved.id
        : null;
  }

  static String _payloadHash(String payloadId) => 'capture_payload:$payloadId';

  /// Prefetches the current accounts once per sync run into a first-match-per-
  /// currency map (mirroring the previous linear scan) and records the total for
  /// create-on-miss bookkeeping.
  Future<Map<String, AccountEntity>> _buildCurrencyAccountCache() async {
    final repository = _accountRepository;
    if (repository == null) {
      _currencyAccountTotal = 0;
      return {};
    }
    final accounts = await repository.getAll();
    _currencyAccountTotal = accounts.length;
    final cache = <String, AccountEntity>{};
    for (final account in accounts) {
      cache.putIfAbsent(account.currency.trim().toUpperCase(), () => account);
    }
    return cache;
  }

  Future<AccountEntity> _createAccountForCurrency(
    AccountRepository repository,
    String normalized, {
    required bool isDefault,
    required int sortOrder,
  }) {
    final now = DateTime.now().toUtc();
    return repository.create(
      AccountEntity(
        id: '',
        name: 'حساب $normalized',
        currency: normalized,
        type: AccountType.bank,
        isDefault: isDefault,
        sortOrder: sortOrder,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<AccountEntity?> _accountForCurrency(String currency) async {
    final normalized = currency.trim().toUpperCase();
    if (normalized.isEmpty) return null;
    final repository = _accountRepository;
    if (repository == null) return null;

    // Fast path: the run-scoped cache (one getAll() for the whole batch).
    final cache = _currencyAccountCache;
    if (cache != null) {
      final hit = cache[normalized];
      if (hit != null) return hit;
      final created = await _createAccountForCurrency(
        repository,
        normalized,
        isDefault: _currencyAccountTotal == 0,
        sortOrder: _currencyAccountTotal,
      );
      _currencyAccountTotal++;
      cache[normalized] = created;
      return created;
    }

    // Fallback (no active sync run): the original per-call behavior.
    final accounts = await repository.getAll();
    for (final account in accounts) {
      if (account.currency.trim().toUpperCase() == normalized) {
        return account;
      }
    }
    return _createAccountForCurrency(
      repository,
      normalized,
      isDefault: accounts.isEmpty,
      sortOrder: accounts.length,
    );
  }

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
