import '../../core/utils/id_generator.dart';
import '../../data/catalog/catalog_daos.dart';
import '../../engine/ai/ai_parser_client.dart';
import '../../engine/ai/ai_sender_failure_tracker.dart';
import '../../engine/ai/grounding_check.dart';
import '../../engine/categorization/categorizer.dart';
import '../../engine/categorization/merchant_category_map.dart';
import '../../engine/dedup/transaction_dedup.dart';
import '../../engine/models/parsed_transaction.dart';
import '../../engine/models/transaction_source.dart';
import '../../engine/models/transaction_type.dart';
import '../../engine/parser/bank_profile.dart';
import '../../engine/parser/parser_isolate.dart';
import '../../engine/parser/parse_result.dart';
import '../../engine/privacy/sms_sanitizer.dart';
import '../entities/engagement_entities.dart';
import '../entities/transaction_entity.dart';
import '../repositories/account_repository.dart';
import '../repositories/dedup_store.dart';
import '../repositories/merchant_category_repository.dart';
import '../repositories/transaction_repository.dart';
import '../services/bank_discovery_service.dart';
import 'engagement_usecase.dart';
import 'resolve_bank_for_sender_usecase.dart';

class AddTransactionResult {
  const AddTransactionResult._({
    required this.outcome,
    this.transaction,
    this.parseResult,
    this.isNewMerchant = false,
  });

  const AddTransactionResult.added(
      TransactionEntity transaction, ParseResult parseResult,
      {bool isNewMerchant = false})
      : this._(
          outcome: AddTransactionOutcome.added,
          transaction: transaction,
          parseResult: parseResult,
          isNewMerchant: isNewMerchant,
        );

  const AddTransactionResult.duplicate(TransactionEntity transaction)
      : this._(
          outcome: AddTransactionOutcome.duplicate,
          transaction: transaction,
        );

  const AddTransactionResult.notTransaction(ParseResult parseResult)
      : this._(
          outcome: AddTransactionOutcome.notTransaction,
          parseResult: parseResult,
        );

  final AddTransactionOutcome outcome;
  final TransactionEntity? transaction;
  final ParseResult? parseResult;
  final bool isNewMerchant;

  bool get requiresConfirmation {
    if (outcome != AddTransactionOutcome.added || transaction == null) {
      return false;
    }
    return transaction!.status == TransactionStatus.pending || isNewMerchant;
  }
}

enum AddTransactionOutcome { added, duplicate, notTransaction }

class AddTransactionUseCase {
  AddTransactionUseCase({
    required TransactionRepository transactionRepository,
    required MerchantCategoryRepository merchantCategoryRepository,
    ParserIsolate? parserIsolate,
    RecordEngagementUseCase? recordEngagementUseCase,
    Future<void> Function(String key, {String? dimension})? logMetric,
    Future<List<BankProfile>> Function({String? senderId})? loadBankProfiles,
    Future<List<RemoteMerchantKeyword>> Function()? loadRemoteKeywords,
    Future<void> Function(String normalizedMerchant)? noteMerchantFeedback,
    AccountRepository? accountRepository,
    DedupStore? dedupStore,
    AiParserClient? aiClient,
    Future<bool> Function()? loadAiConsent,
    String? installId,
    ResolveBankForSenderUseCase? resolveBankForSenderUseCase,
    BankDiscoveryService? bankDiscoveryService,
  })  : _transactionRepository = transactionRepository,
        _merchantCategoryRepository = merchantCategoryRepository,
        _parserIsolate = parserIsolate ?? const ParserIsolate(),
        _recordEngagementUseCase = recordEngagementUseCase,
        _logMetric = logMetric,
        _loadBankProfiles = loadBankProfiles,
        _loadRemoteKeywords = loadRemoteKeywords,
        _noteMerchantFeedback = noteMerchantFeedback,
        _accountRepository = accountRepository,
        _dedupStore = dedupStore,
        _aiClient = aiClient,
        _loadAiConsent = loadAiConsent,
        _installId = installId,
        _resolveBankForSenderUseCase = resolveBankForSenderUseCase,
        _bankDiscoveryService = bankDiscoveryService;

  static const double autoConfirmThreshold = 0.92;
  static const double categoryAutoConfirmThreshold = 0.80;

  final TransactionRepository _transactionRepository;
  final MerchantCategoryRepository _merchantCategoryRepository;
  final ParserIsolate _parserIsolate;
  final RecordEngagementUseCase? _recordEngagementUseCase;
  final Future<void> Function(String key, {String? dimension})? _logMetric;
  final Future<List<BankProfile>> Function({String? senderId})?
      _loadBankProfiles;
  final Future<List<RemoteMerchantKeyword>> Function()? _loadRemoteKeywords;
  final Future<void> Function(String normalizedMerchant)? _noteMerchantFeedback;
  final AccountRepository? _accountRepository;
  final DedupStore? _dedupStore;
  final AiParserClient? _aiClient;
  final Future<bool> Function()? _loadAiConsent;
  final String? _installId;
  final ResolveBankForSenderUseCase? _resolveBankForSenderUseCase;
  final BankDiscoveryService? _bankDiscoveryService;

  Future<AddTransactionResult> call({
    required String rawMessage,
    String? senderId,
  }) async {
    final loadedBankProfiles = await _safeLoadBankProfiles(senderId: senderId);
    final bankResolution = await _resolveBankForSender(
      rawMessage: rawMessage,
      senderId: senderId,
      bankProfiles: loadedBankProfiles,
    );
    final bankProfiles = bankResolution.bankProfiles;
    final defaultAccount = await _accountRepository?.getDefault();
    final parseResult = await _parserIsolate.parse(
          rawMessage,
          senderId: senderId,
          bankProfiles: bankProfiles,
          defaultCurrency: defaultAccount?.currency ?? 'SAR',
        ) ??
        ParseResult.notTransaction();
    // B.3 sender diagnostic — remove after on-device sender test is confirmed.
    // ignore: avoid_print
    print(
        '[Mali] parse: bankKey=${parseResult.bankKey ?? "<none>"} senderId=$senderId conf=${parseResult.confidence.toStringAsFixed(2)} isTxn=${parseResult.isTransaction}');

    await _runBankDiscoveryIfEligible(
      rawMessage: rawMessage,
      senderId: senderId,
      bankProfiles: loadedBankProfiles,
      parseResult: parseResult,
      localeHint: defaultAccount?.currency,
    );

    if (!parseResult.isTransaction || parseResult.transaction == null) {
      return AddTransactionResult.notTransaction(parseResult);
    }
    await _logMetric?.call('parse_success', dimension: parseResult.bankKey);

    final parsed = parseResult.transaction!;
    final occurredAt = parsed.occurredAt ?? DateTime.now().toUtc();

    // Hash-based dedup: catches no-merchant transactions the merchant check misses.
    // Hash key = {amount, currency, cardLast4, merchant_normalized, type} — no time.
    // Time window (±5 min) is enforced in DedupStore via sliding julianday query,
    // so there are no fixed-bucket boundary misses.
    if (_dedupStore != null) {
      final hash = await TransactionDedup.computeHash(
        amount: parsed.amount,
        currency: parsed.currency,
        cardLast4: parsed.cardLast4,
        merchantNormalized: parsed.rawMerchant != null
            ? TransactionDedup.normalizeMerchant(parsed.rawMerchant!)
            : null,
        type: parsed.type.name,
      );
      final existingId = await _dedupStore.transactionIdFor(hash, occurredAt);
      if (existingId != null) {
        final existing = await _transactionRepository.getById(existingId);
        if (existing != null) {
          return AddTransactionResult.duplicate(existing);
        }
        // Hash exists but transaction was deleted; fall through and re-save.
      }
    }

    final merchant = parsed.rawMerchant;
    final now = DateTime.now().toUtc();
    final isNewMerchant = merchant == null
        ? false
        : !await _merchantCategoryRepository.hasCategoryForMerchant(merchant);

    if (merchant != null) {
      final duplicate = await _transactionRepository.findDuplicate(
        amount: parsed.amount,
        rawMerchant: merchant,
        occurredAt: occurredAt,
      );
      if (duplicate != null) {
        return AddTransactionResult.duplicate(duplicate);
      }
    }

    final learnedMap =
        await _merchantCategoryRepository.getLearnedCategoryMap();
    final loader = _loadRemoteKeywords;
    final remoteKeywords =
        loader != null ? await loader() : const <RemoteMerchantKeyword>[];
    final categorizer = Categorizer(
      map: MerchantCategoryMap(learnedMap),
      remoteKeywords: remoteKeywords,
    );
    final categoryResult = categorizer.categorize(parsed);

    // ── AI cascade ────────────────────────────────────────────────────────────
    // Fires only when confidence is below pending threshold (< 0.70).
    // A generic rule-based parse that already reached pending-level confidence
    // is saved as pending without spending an AI call, even if categorization
    // falls back to Other.
    var effectiveParsed = parsed;
    var effectiveCategory = categoryResult;

    final aiTriggered =
        parsed.parseConfidence < 0.70 && !bankResolution.suppressesDiscovery;

    if (aiTriggered && _aiClient != null) {
      final consent = await _loadAiConsent?.call() ?? false;
      final sid = senderId ?? '';
      if (consent && !AiSenderFailureTracker.instance.isSuppressed(sid)) {
        final sanitized =
            SmsSanitizer.sanitize(rawMessage, detectedType: parsed.type);
        final aiResponse = await _aiClient.parse(
          sanitizedSms: sanitized,
          senderId: sid,
          installId: _installId ?? '',
        );
        if (aiResponse != null) {
          if (!GroundingCheck.verify(
            amount: aiResponse.amount,
            sanitizedText: sanitized,
          )) {
            AiSenderFailureTracker.instance.recordFailure(sid);
            return AddTransactionResult.notTransaction(parseResult);
          }
          AiSenderFailureTracker.instance.recordSuccess(sid);
          final aiType = _parseTypeFromString(aiResponse.type) ?? parsed.type;
          // Confidence capped at 0.79 — AI results always route to pending.
          effectiveParsed = ParsedTransaction(
            amount: aiResponse.amount,
            currency: aiResponse.currency,
            type: aiType,
            source: TransactionSource.aiParsed,
            rawMerchant: aiResponse.merchantName ?? parsed.rawMerchant,
            cardLast4: parsed.cardLast4,
            balanceAfter: parsed.balanceAfter,
            occurredAt: parsed.occurredAt,
            foreignAmount: parsed.foreignAmount,
            foreignCurrency: parsed.foreignCurrency,
            fundingSource: parsed.fundingSource,
            parseConfidence: 0.79,
          );
          effectiveCategory = aiResponse.categoryKey != null
              ? CategoryResult(
                  aiResponse.categoryKey!, CategorySource.keyword, 0.85)
              : categorizer.categorize(effectiveParsed);
        }
      }
    }

    // Anonymous merchant feedback — ONLY for POS/payment types.
    // Transfers and income carry beneficiary/payer names (real people), not
    // business names. Recording those would be the same privacy leak fixed in
    // 4A via SmsSanitizer. Unknown type also excluded (cannot confirm it is a
    // business).
    final noter = _noteMerchantFeedback;
    final isBusinessMerchant =
        effectiveParsed.type == TransactionType.payment ||
            effectiveParsed.type == TransactionType.refund;
    if (effectiveCategory.source == CategorySource.fallback &&
        effectiveParsed.rawMerchant != null &&
        isBusinessMerchant &&
        noter != null) {
      final normalized =
          TransactionDedup.normalizeMerchant(effectiveParsed.rawMerchant!);
      if (normalized.isNotEmpty) {
        await noter(normalized);
      }
    }
    final canAutoConfirm =
        effectiveParsed.parseConfidence >= autoConfirmThreshold &&
            effectiveCategory.confidence >= categoryAutoConfirmThreshold &&
            !isNewMerchant;

    final transaction = TransactionEntity(
      id: IdGenerator.next(),
      amount: effectiveParsed.amount,
      currency: effectiveParsed.currency,
      accountId: defaultAccount?.id,
      merchantId: null,
      rawMerchant: effectiveParsed.rawMerchant,
      categoryId: null,
      type: _mapType(effectiveParsed.type),
      source: _mapSource(effectiveParsed.source),
      cardLast4: effectiveParsed.cardLast4,
      balanceAfter: effectiveParsed.balanceAfter,
      occurredAt: occurredAt.toUtc(),
      rawMessage: rawMessage,
      parseConfidence: effectiveParsed.parseConfidence,
      status: canAutoConfirm
          ? TransactionStatus.confirmed
          : TransactionStatus.pending,
      createdAt: now,
      updatedAt: now,
    );

    final saved = await _transactionRepository.saveTransaction(
      transaction: transaction,
      categoryKey: effectiveCategory.categoryKey,
    );
    if (_recordEngagementUseCase != null) {
      await _recordEngagementUseCase(
        action: saved.status == TransactionStatus.confirmed
            ? EngagementAction.transactionConfirmed
            : EngagementAction.transactionAdded,
        occurredAt: saved.occurredAt,
      );
    }

    // Mark dedup hash after successful save.
    if (_dedupStore != null) {
      final hash = await TransactionDedup.computeHash(
        amount: effectiveParsed.amount,
        currency: effectiveParsed.currency,
        cardLast4: effectiveParsed.cardLast4,
        merchantNormalized: effectiveParsed.rawMerchant != null
            ? TransactionDedup.normalizeMerchant(effectiveParsed.rawMerchant!)
            : null,
        type: effectiveParsed.type.name,
      );
      await _dedupStore.mark(
        hash,
        transactionId: transaction.id,
        occurredAt: occurredAt,
      );
    }

    await _logMetric?.call('first_transaction_captured');
    return AddTransactionResult.added(
      saved,
      parseResult,
      isNewMerchant: isNewMerchant,
    );
  }

  Future<List<BankProfile>> _safeLoadBankProfiles({String? senderId}) async {
    final loader = _loadBankProfiles;
    if (loader == null) return const [];
    try {
      return await loader(senderId: senderId);
    } catch (_) {
      return const [];
    }
  }

  Future<BankSenderResolution> _resolveBankForSender({
    required String rawMessage,
    required String? senderId,
    required List<BankProfile> bankProfiles,
  }) async {
    final resolver = _resolveBankForSenderUseCase;
    if (resolver == null) {
      return BankSenderResolution(
        source: BankSenderResolutionSource.unknown,
        bankProfiles: bankProfiles,
      );
    }
    try {
      return await resolver(
        rawMessage: rawMessage,
        senderId: senderId,
        bankProfiles: bankProfiles,
      );
    } catch (_) {
      return BankSenderResolution(
        source: BankSenderResolutionSource.unknown,
        bankProfiles: bankProfiles,
      );
    }
  }

  Future<void> _runBankDiscoveryIfEligible({
    required String rawMessage,
    required String? senderId,
    required List<BankProfile> bankProfiles,
    required ParseResult parseResult,
    String? localeHint,
  }) async {
    final service = _bankDiscoveryService;
    if (service == null) return;
    try {
      await service.discoverIfEligible(
        rawSms: rawMessage,
        senderId: senderId,
        availableProfiles: bankProfiles,
        parseResult: parseResult,
        localeHint: localeHint,
      );
    } catch (_) {
      // Bank discovery is advisory only; parsing and local capture must continue.
    }
  }

  static TransactionSourceEntity _mapSource(TransactionSource source) {
    switch (source) {
      case TransactionSource.bank:
        return TransactionSourceEntity.bank;
      case TransactionSource.card:
        return TransactionSourceEntity.card;
      case TransactionSource.wallet:
        return TransactionSourceEntity.wallet;
      case TransactionSource.unknown:
        return TransactionSourceEntity.unknown;
      case TransactionSource.aiParsed:
        return TransactionSourceEntity.aiParsed;
    }
  }

  static TransactionType? _parseTypeFromString(String? raw) {
    switch (raw) {
      case 'payment':
        return TransactionType.payment;
      case 'withdrawal':
        return TransactionType.withdrawal;
      case 'transfer':
        return TransactionType.transfer;
      case 'income':
        return TransactionType.income;
      case 'refund':
        return TransactionType.refund;
      default:
        return null;
    }
  }

  static TransactionTypeEntity _mapType(TransactionType type) {
    switch (type) {
      case TransactionType.payment:
        return TransactionTypeEntity.payment;
      case TransactionType.withdrawal:
        return TransactionTypeEntity.withdrawal;
      case TransactionType.transfer:
        return TransactionTypeEntity.transfer;
      case TransactionType.refund:
        return TransactionTypeEntity.refund;
      case TransactionType.income:
        return TransactionTypeEntity.income;
      case TransactionType.creditCardPayment:
      case TransactionType.governmentPayment:
        return TransactionTypeEntity.payment;
      case TransactionType.unknown:
        return TransactionTypeEntity.unknown;
    }
  }
}

class SaveManualTransactionUseCase {
  SaveManualTransactionUseCase({
    required TransactionRepository transactionRepository,
    RecordEngagementUseCase? recordEngagementUseCase,
    Future<void> Function(String key, {String? dimension})? logMetric,
  })  : _transactionRepository = transactionRepository,
        _recordEngagementUseCase = recordEngagementUseCase,
        _logMetric = logMetric;

  final TransactionRepository _transactionRepository;
  final RecordEngagementUseCase? _recordEngagementUseCase;
  final Future<void> Function(String key, {String? dimension})? _logMetric;

  Future<TransactionEntity> call({
    required double amount,
    required String currency,
    required TransactionTypeEntity type,
    required DateTime occurredAt,
    required String categoryKey,
    String? merchant,
    String? note,
    String? accountId,
  }) async {
    final now = DateTime.now().toUtc();
    final normalizedMerchant = merchant?.trim();
    final normalizedNote = note?.trim();
    final transaction = TransactionEntity(
      id: IdGenerator.next(),
      amount: amount,
      currency: currency.toUpperCase(),
      accountId: accountId,
      merchantId: null,
      rawMerchant: normalizedMerchant == null || normalizedMerchant.isEmpty
          ? null
          : normalizedMerchant,
      categoryId: null,
      type: type,
      source: TransactionSourceEntity.unknown,
      cardLast4: null,
      balanceAfter: null,
      note: normalizedNote == null || normalizedNote.isEmpty
          ? null
          : normalizedNote,
      occurredAt: occurredAt.toUtc(),
      rawMessage: normalizedNote == null || normalizedNote.isEmpty
          ? 'Manual transaction'
          : normalizedNote,
      parseConfidence: 1,
      status: TransactionStatus.confirmed,
      createdAt: now,
      updatedAt: now,
    );

    final saved = await _transactionRepository.saveTransaction(
      transaction: transaction,
      categoryKey: categoryKey,
    );
    if (_recordEngagementUseCase != null) {
      await _recordEngagementUseCase(
        action: EngagementAction.transactionConfirmed,
        occurredAt: saved.occurredAt,
      );
    }
    await _logMetric?.call('manual_transaction_added');
    return saved;
  }
}
