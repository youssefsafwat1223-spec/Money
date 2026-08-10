import '../../core/utils/id_generator.dart';
import '../../data/catalog/catalog_daos.dart';
import '../../engine/ai/ai_parser_client.dart';
import '../../engine/ai/ai_sender_failure_tracker.dart';
import '../../engine/ai/grounding_check.dart';
import '../../engine/categorization/category.dart';
import '../../engine/categorization/categorizer.dart';
import '../../engine/categorization/merchant_category_map.dart';
import '../../engine/dedup/transaction_dedup.dart';
import '../../engine/models/parsed_transaction.dart';
import '../../engine/models/transaction_source.dart';
import '../../engine/models/transaction_type.dart';
import '../../engine/parser/bank_profile.dart';
import '../../engine/parser/payment_aggregators.dart';
import '../../engine/parser/bank_sender_filter.dart';
import '../../engine/parser/direction_signal.dart';
import '../../engine/parser/parser_engine.dart';
import '../../engine/parser/parser_isolate.dart';
import '../../engine/parser/parse_result.dart';
import '../../engine/parser/transaction_timestamp_extractor.dart';
import '../../engine/privacy/sms_sanitizer.dart';
import '../entities/account_entity.dart';
import '../entities/engagement_entities.dart';
import '../entities/suspected_duplicate_entity.dart';
import '../entities/transaction_entity.dart';
import '../repositories/account_repository.dart';
import '../repositories/dedup_store.dart';
import '../repositories/merchant_category_repository.dart';
import '../repositories/suspected_duplicate_repository.dart';
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
    this.droppedByParser = false,
    this.aiFailureReason,
    this.secondary,
    this.suspectedDuplicateId,
    this.duplicateReason,
  });

  const AddTransactionResult.added(
      TransactionEntity transaction, ParseResult parseResult,
      {bool isNewMerchant = false, AddTransactionResult? secondary})
      : this._(
          outcome: AddTransactionOutcome.added,
          transaction: transaction,
          parseResult: parseResult,
          isNewMerchant: isNewMerchant,
          secondary: secondary,
        );

  const AddTransactionResult.duplicate(TransactionEntity transaction,
      {AddTransactionResult? secondary})
      : this._(
          outcome: AddTransactionOutcome.duplicate,
          transaction: transaction,
          secondary: secondary,
        );

  const AddTransactionResult.suspiciousDuplicate(
    TransactionEntity transaction, {
    String? suspectedDuplicateId,
    String? duplicateReason,
  }) : this._(
          outcome: AddTransactionOutcome.suspiciousDuplicate,
          transaction: transaction,
          suspectedDuplicateId: suspectedDuplicateId,
          duplicateReason: duplicateReason,
        );

  const AddTransactionResult.notTransaction(ParseResult parseResult,
      {bool droppedByParser = false, String? aiFailureReason})
      : this._(
          outcome: AddTransactionOutcome.notTransaction,
          parseResult: parseResult,
          droppedByParser: droppedByParser,
          aiFailureReason: aiFailureReason,
        );

  final AddTransactionOutcome outcome;
  final TransactionEntity? transaction;
  final ParseResult? parseResult;
  final bool isNewMerchant;

  /// True when a bank-like message was not OTP/promo but couldn't be parsed.
  final bool droppedByParser;
  final String? aiFailureReason;
  final String? suspectedDuplicateId;
  final String? duplicateReason;

  /// A second transaction extracted from the same SMS — currently a fee/tax
  /// line charged in a different currency than the main amount. Null when the
  /// message holds a single operation.
  final AddTransactionResult? secondary;

  bool get requiresConfirmation {
    if (outcome != AddTransactionOutcome.added || transaction == null) {
      return false;
    }
    return transaction!.status == TransactionStatus.pending || isNewMerchant;
  }
}

enum AddTransactionOutcome {
  added,
  duplicate,
  suspiciousDuplicate,
  notTransaction,
}

class _AiFirstAttempt {
  const _AiFirstAttempt({
    required this.senderId,
    this.sanitizedSms,
    this.response,
    this.failureReason,
  });

  const _AiFirstAttempt.skipped([String? reason])
      : senderId = '',
        sanitizedSms = null,
        response = null,
        failureReason = reason;

  final String senderId;
  final String? sanitizedSms;
  final AiParseResponse? response;
  final String? failureReason;
}

class _AppliedAiParse {
  const _AppliedAiParse({
    required this.transaction,
    required this.categoryKey,
    required this.direction,
  });

  final ParsedTransaction transaction;
  final String? categoryKey;
  final TransactionDirectionEntity? direction;
}

Future<AccountEntity?> _accountForCurrency(
  AccountRepository? repository,
  String currency, {
  AccountEntity? fallback,
}) async {
  final normalized = currency.trim().toUpperCase();
  if (normalized.isEmpty) return fallback;
  if (fallback != null && fallback.currency.toUpperCase() == normalized) {
    return fallback;
  }
  if (repository == null) return fallback;

  final accounts = await repository.getAll();
  for (final account in accounts) {
    if (account.currency.toUpperCase() == normalized) {
      return account;
    }
  }

  final now = DateTime.now().toUtc();
  return repository.create(
    AccountEntity(
      id: '',
      name: 'حساب $normalized',
      currency: normalized,
      type: AccountType.bank,
      isDefault: accounts.isEmpty,
      sortOrder: accounts.length,
      createdAt: now,
      updatedAt: now,
    ),
  );
}

/// يطابق رقم الحساب المُستخرَج من الرسالة مع bank_account_number لحساب موجود.
/// أولوية أعلى من مطابقة العملة، لكن لا يُنشئ حسابًا أبدًا (يعيد null لو لا مطابقة).
/// المطابقة: تطابق تام، أو تطابق لاحقة (لأرقام مُقنّعة/جزئية) بطول 4+ خانات.
Future<AccountEntity?> _accountByNumber(
  AccountRepository? repository,
  String? parsedAccountNumber, {
  List<AccountEntity>? accounts,
}) async {
  if (repository == null) return null;
  final needle = parsedAccountNumber?.replaceAll(RegExp(r'[^0-9]'), '');
  if (needle == null || needle.length < 4) return null;
  final list = accounts ?? await repository.getAll();
  AccountEntity? suffixMatch;
  for (final account in list) {
    final stored = account.bankAccountNumber?.replaceAll(RegExp(r'[^0-9]'), '');
    if (stored == null || stored.length < 4) continue;
    if (stored == needle) return account; // تطابق تام له الأولوية.
    final shorter = stored.length <= needle.length ? stored : needle;
    final longer = stored.length <= needle.length ? needle : stored;
    if (shorter.length >= 4 && longer.endsWith(shorter)) {
      suffixMatch ??= account;
    }
  }
  return suffixMatch;
}

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
    Future<String?> Function(String normalizedMerchant)?
        resolveMerchantCategory,
    AccountRepository? accountRepository,
    DedupStore? dedupStore,
    AiParserClient? aiClient,
    Future<bool> Function()? loadAiConsent,
    String? installId,
    Future<String> Function()? loadInstallId,
    ResolveBankForSenderUseCase? resolveBankForSenderUseCase,
    BankDiscoveryService? bankDiscoveryService,
    SuspectedDuplicateRepository? suspectedDuplicateRepository,
  })  : _transactionRepository = transactionRepository,
        _merchantCategoryRepository = merchantCategoryRepository,
        _parserIsolate = parserIsolate ?? const ParserIsolate(),
        _recordEngagementUseCase = recordEngagementUseCase,
        _logMetric = logMetric,
        _loadBankProfiles = loadBankProfiles,
        _loadRemoteKeywords = loadRemoteKeywords,
        _noteMerchantFeedback = noteMerchantFeedback,
        _resolveMerchantCategory = resolveMerchantCategory,
        _accountRepository = accountRepository,
        _dedupStore = dedupStore,
        _aiClient = aiClient,
        _loadAiConsent = loadAiConsent,
        _installId = installId,
        _loadInstallId = loadInstallId,
        _resolveBankForSenderUseCase = resolveBankForSenderUseCase,
        _bankDiscoveryService = bankDiscoveryService,
        _suspectedDuplicateRepository = suspectedDuplicateRepository;

  static const double autoConfirmThreshold = 0.92;
  static const double categoryAutoConfirmThreshold = 0.80;

  final TransactionRepository _transactionRepository;
  final MerchantCategoryRepository _merchantCategoryRepository;
  final SuspectedDuplicateRepository? _suspectedDuplicateRepository;
  final ParserIsolate _parserIsolate;
  final RecordEngagementUseCase? _recordEngagementUseCase;
  final Future<void> Function(String key, {String? dimension})? _logMetric;
  final Future<List<BankProfile>> Function({String? senderId})?
      _loadBankProfiles;
  final Future<List<RemoteMerchantKeyword>> Function()? _loadRemoteKeywords;
  final Future<void> Function(String normalizedMerchant)? _noteMerchantFeedback;
  final Future<String?> Function(String normalizedMerchant)?
      _resolveMerchantCategory;
  final AccountRepository? _accountRepository;
  final DedupStore? _dedupStore;
  final AiParserClient? _aiClient;
  final Future<bool> Function()? _loadAiConsent;
  final String? _installId;
  final Future<String> Function()? _loadInstallId;
  final ResolveBankForSenderUseCase? _resolveBankForSenderUseCase;
  final BankDiscoveryService? _bankDiscoveryService;

  Future<AddTransactionResult> call({
    required String rawMessage,
    String? senderId,
    bool skipDedup = false,
    DateTime? smsReceivedAt,
  }) async {
    final loadedBankProfiles = await _safeLoadBankProfiles(senderId: senderId);
    final bankResolution = await _resolveBankForSender(
      rawMessage: rawMessage,
      senderId: senderId,
      bankProfiles: loadedBankProfiles,
    );
    final bankProfiles = bankResolution.bankProfiles;
    final defaultAccount = await _accountRepository?.getDefault();

    // Pre-classify message before parsing so we can surface unprocessable cases.
    final isLikelyBank =
        BankSenderFilter.isLikelyBank(senderId, text: rawMessage);
    final wasIgnored = isLikelyBank
        ? ParserEngine.isIgnoredMessage(rawMessage,
            senderId: senderId, bankProfiles: bankProfiles)
        : false;

    final aiFirstAttempt = wasIgnored
        ? const _AiFirstAttempt.skipped('message_ignored')
        : await _tryAiParseFirst(
            rawMessage: rawMessage,
            senderId: senderId,
          );

    final parseResult = await _parserIsolate.parse(
          rawMessage,
          senderId: senderId,
          bankProfiles: bankProfiles,
          defaultCurrency: defaultAccount?.currency ?? 'SAR',
        ) ??
        ParseResult.notTransaction();

    await _runBankDiscoveryIfEligible(
      rawMessage: rawMessage,
      senderId: senderId,
      bankProfiles: loadedBankProfiles,
      parseResult: parseResult,
      localeHint: defaultAccount?.currency,
    );

    final localParsed =
        parseResult.isTransaction ? parseResult.transaction : null;
    if (localParsed != null) {
      await _logMetric?.call('parse_success', dimension: parseResult.bankKey);
    }

    final aiParsed = _applyAiResponse(
      attempt: aiFirstAttempt,
      rawMessage: rawMessage,
      localParsed: localParsed,
    );

    ParsedTransaction parsed;
    String? aiCategoryKey;
    TransactionDirectionEntity? aiDirection;
    if (aiParsed != null) {
      parsed = aiParsed.transaction;
      aiCategoryKey = aiParsed.categoryKey;
      aiDirection = aiParsed.direction;
      if (localParsed == null) {
        await _logMetric?.call('ai_first_parse');
      }
    } else if (localParsed != null) {
      parsed = localParsed;
    } else {
      final fallbackParsed = aiFirstAttempt.failureReason == null
          ? _lastResortParse(rawMessage)
          : null;
      if (fallbackParsed != null) {
        parsed = fallbackParsed;
      } else {
        // The AI had the first chance and the rule-based parser still couldn't
        // read it. For a bank-like sender, surface that it was dropped by parsing
        // so the UI can avoid a noisy "unreadable message" dead end.
        final droppedByParser = isLikelyBank && !wasIgnored;
        return AddTransactionResult.notTransaction(parseResult,
            droppedByParser: droppedByParser,
            aiFailureReason: aiFirstAttempt.failureReason ??
                (aiFirstAttempt.response == null
                    ? null
                    : 'ai_response_rejected_by_grounding'));
      }
    }
    final now = DateTime.now().toUtc();
    final receivedAt = (smsReceivedAt ?? now).toUtc();
    final transactionTimeFromSms =
        (parsed.occurredAt ?? TransactionTimestampExtractor.extract(rawMessage))
            ?.toUtc();
    final comparisonTimestamp = transactionTimeFromSms ?? receivedAt;
    final comparisonTimestampSource = transactionTimeFromSms == null
        ? ComparisonTimestampSource.receivedAt
        : ComparisonTimestampSource.smsBody;
    final occurredAt = comparisonTimestamp;
    if (parsed.occurredAt == null && transactionTimeFromSms != null) {
      parsed = parsed.copyWith(occurredAt: transactionTimeFromSms);
    }

    // Payment aggregators (Fawry, …) are gateways, not the real merchant. When
    // the SMS reads "Fawry <merchant>", strip the gateway so the underlying
    // merchant (e.g. the restaurant) drives dedup, categorization, and the
    // brand logo instead of the gateway.
    parsed = parsed.copyWith(
      rawMerchant: PaymentAggregators.resolveMerchant(parsed.rawMerchant),
    );

    final merchant = parsed.rawMerchant;
    // Pre-categorize to determine if keyword match exists — known merchants
    // (Starbucks, Amazon, etc.) should not require confirmation even on first visit.
    final preCategory = Categorizer(
      remoteKeywords: const [],
    ).categorize(parsed);
    final isNewMerchant = merchant == null
        ? false
        : preCategory.source == CategorySource.fallback &&
            !await _merchantCategoryRepository.hasCategoryForMerchant(merchant);

    if (!skipDedup) {
      final duplicate = await _transactionRepository.findSuspiciousDuplicate(
        amount: parsed.amount,
        currency: parsed.currency,
        merchantOrDescription: parsed.rawMerchant ?? rawMessage,
        cardLast4: parsed.cardLast4,
        comparisonTimestamp: comparisonTimestamp,
      );
      if (duplicate != null) {
        const reason = 'same amount, currency, merchant and comparison time';
        final suspectedId = await _saveSuspectedDuplicate(
          rawMessage: rawMessage,
          senderId: senderId,
          existingTransactionId: duplicate.id,
          parsed: parsed,
          occurredAt: occurredAt,
          cardLast4: parsed.cardLast4,
          comparisonTimestamp: comparisonTimestamp,
          comparisonTimestampSource: comparisonTimestampSource,
          duplicateReason: reason,
        );
        return AddTransactionResult.suspiciousDuplicate(
          duplicate,
          suspectedDuplicateId: suspectedId,
          duplicateReason: reason,
        );
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
    var effectiveParsed = parsed;
    final hasAiCategory = aiCategoryKey != null;
    final hasSpecificAiCategory = hasAiCategory &&
        aiCategoryKey != Categories.other.key &&
        Categories.byKey(aiCategoryKey) != Categories.other;
    var effectiveCategory = hasAiCategory
        ? CategoryResult(
            Categories.byKey(aiCategoryKey).key,
            hasSpecificAiCategory
                ? CategorySource.keyword
                : CategorySource.fallback,
            hasSpecificAiCategory ? 0.85 : 0.3,
          )
        : categorizer.categorize(effectiveParsed);

    // Transfer accounting — mirrors mainstream finance apps:
    //   • internal / own-account move → neutral transfer (excluded from totals)
    //   • a cash/ATM deposit (إيداع)   → neutral transfer (cash you already had)
    //   • money RECEIVED from outside  → income  (counts toward income)
    //   • money SENT outside           → expense (counts toward spending)
    // Beneficiary/payer names are dropped (real people, not businesses). The
    // wording grounds the direction, so it works for both the rule parser and AI.
    // Resolve the money direction ONCE from all signals (AI → wording → type)
    // so the income/expense bucket, the stored direction and the row's +/− can
    // never disagree (an AI "credit" must not land in the expense total).
    final resolvedDirection = aiDirection ??
        _directionFromText(rawMessage) ??
        _directionFromType(effectiveParsed.type);
    final incoming = resolvedDirection == TransactionDirectionEntity.credit;
    final isNeutralTransfer = looksLikeInternalTransfer(rawMessage) ||
        (incoming && effectiveParsed.type == TransactionType.withdrawal);
    final isExternalTransfer = !isNeutralTransfer &&
        (effectiveParsed.type == TransactionType.transfer ||
            _looksLikeTransferMessage(rawMessage));
    if (isNeutralTransfer) {
      effectiveParsed = _replaceMerchant(
        effectiveParsed.copyWith(type: TransactionType.transfer),
        null,
      );
      effectiveCategory = CategoryResult(
        Categories.transfers.key,
        CategorySource.typeRule,
        0.95,
      );
    } else if (isExternalTransfer) {
      effectiveParsed = _replaceMerchant(
        effectiveParsed.copyWith(
          type: incoming ? TransactionType.income : TransactionType.payment,
        ),
        null,
      );
      effectiveCategory = CategoryResult(
        incoming ? Categories.income.key : Categories.transfers.key,
        CategorySource.typeRule,
        0.9,
      );
    } else if (effectiveParsed.type == TransactionType.income) {
      effectiveParsed = _replaceMerchant(effectiveParsed, null);
      effectiveCategory = CategoryResult(
        Categories.income.key,
        CategorySource.typeRule,
        0.95,
      );
    } else if (effectiveParsed.type == TransactionType.withdrawal) {
      effectiveCategory = CategoryResult(
        Categories.cash.key,
        CategorySource.typeRule,
        0.95,
      );
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
        isBusinessMerchant) {
      final normalized =
          TransactionDedup.normalizeMerchant(effectiveParsed.rawMerchant!);
      if (normalized.isNotEmpty) {
        // Real-time assist: rules and AI both fell back to "other", so ask the
        // server (Google Places via enrich-merchant) to resolve a category. The
        // function also writes the result into merchant_keywords, so every other
        // device picks it up on the next catalog sync.
        final resolver = _resolveMerchantCategory;
        final resolved = resolver != null ? await resolver(normalized) : null;
        if (resolved != null && resolved.isNotEmpty && resolved != 'other') {
          effectiveCategory =
              CategoryResult(resolved, CategorySource.keyword, 0.85);
        } else if (noter != null) {
          // Places couldn't resolve it either — keep the anonymous feedback
          // queue so an admin can map it manually.
          await noter(normalized);
        }
        if (effectiveCategory.categoryKey == Categories.other.key) {
          effectiveCategory = CategoryResult(
            _bestEffortMerchantCategory(normalized),
            CategorySource.fallback,
            0.55,
          );
        }
      }
    }
    if (effectiveCategory.categoryKey == Categories.cash.key &&
        effectiveParsed.type == TransactionType.payment &&
        _looksLikeBankAtmCardTransaction(
          rawMessage,
          merchantName: effectiveParsed.rawMerchant,
        )) {
      effectiveParsed =
          effectiveParsed.copyWith(type: TransactionType.withdrawal);
    }
    // Independent direction grounding: if the wording clearly contradicts the
    // classified type (e.g. an "إيداع/deposit" message tagged as a payment),
    // never auto-confirm — route it to pending for review regardless of score.
    final directionContradiction =
        DirectionSignal.contradicts(rawMessage, effectiveParsed.type);
    final canAutoConfirm =
        effectiveParsed.parseConfidence >= autoConfirmThreshold &&
            effectiveCategory.confidence >= categoryAutoConfirmThreshold &&
            !isNewMerchant &&
            !directionContradiction;
    // Foreign-currency spend on a home-currency card: park it in the home
    // account with amount=0 ("awaiting pricing") so the user can enter the
    // home-currency value later via the details screen.
    // Only applies when the SMS itself contains a fee in the home currency —
    // that fee proves the card is a home-currency card paying in a foreign
    // currency (e.g. SAR card used for a USD purchase). Without that signal
    // we assume the SMS belongs to a different account and auto-create one.
    final homeCurrency = defaultAccount?.currency.trim().toUpperCase();
    final txCurrency = effectiveParsed.currency.trim().toUpperCase();
    final isSpend = effectiveParsed.type == TransactionType.payment ||
        effectiveParsed.type == TransactionType.withdrawal;
    final fee = _extractFeeAmount(rawMessage);
    final hasHomeCurrencyFee = fee != null &&
        homeCurrency != null &&
        fee.$2.trim().toUpperCase() == homeCurrency;
    final foreignUnpriced = homeCurrency != null &&
        homeCurrency.isNotEmpty &&
        txCurrency.isNotEmpty &&
        txCurrency != homeCurrency &&
        isSpend &&
        hasHomeCurrencyFee &&
        await _existingAccountForCurrency(txCurrency) == null;

    // أولوية الإسناد: (1) رقم الحساب المطابق لـ bank_account_number إن وُجد،
    // ثم (2) مطابقة العملة، ثم (3) الحساب الافتراضي. لا يمسّ ربط البطاقة (A2).
    final byAccountNumber = foreignUnpriced
        ? null
        : await _accountByNumber(
            _accountRepository,
            effectiveParsed.accountNumber,
          );
    final effectiveAccount = foreignUnpriced
        ? defaultAccount
        : (byAccountNumber ??
            await _accountForCurrency(
              _accountRepository,
              effectiveParsed.currency,
              fallback: defaultAccount,
            ));

    final transaction = TransactionEntity(
      id: IdGenerator.next(),
      amount: foreignUnpriced ? 0 : effectiveParsed.amount,
      currency: foreignUnpriced ? homeCurrency : effectiveParsed.currency,
      accountId: effectiveAccount?.id,
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
      direction: resolvedDirection,
      status: (canAutoConfirm && !foreignUnpriced)
          ? TransactionStatus.confirmed
          : TransactionStatus.pending,
      createdAt: now,
      updatedAt: now,
      foreignAmount: foreignUnpriced
          ? effectiveParsed.amount
          : effectiveParsed.foreignAmount,
      foreignCurrency:
          foreignUnpriced ? txCurrency : effectiveParsed.foreignCurrency,
      transactionTimeFromSms: transactionTimeFromSms,
      smsReceivedAt: receivedAt,
      comparisonTimestamp: comparisonTimestamp,
      comparisonTimestampSource: comparisonTimestampSource,
      duplicateStatus: DuplicateStatus.normal,
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

    // Mark dedup hash after successful save. Keyed on the originally parsed
    // identity (not the reclassified type) so it matches the pre-save lookup
    // even when an external transfer is re-typed to income/expense.
    if (_dedupStore != null) {
      final hash = await TransactionDedup.computeHash(
        amount: parsed.amount,
        currency: parsed.currency,
        cardLast4: parsed.cardLast4,
        merchantNormalized: _dedupFingerprint(
          parsed,
          rawMessage: rawMessage,
        ),
        type: parsed.type.name,
      );
      await _dedupStore.mark(
        hash,
        transactionId: transaction.id,
        occurredAt: occurredAt,
      );
    }

    // Only now that the primary spend is genuinely new do we add any fee/tax
    // line from the same SMS. Doing it here (not before the dedup checks) means
    // re-pasting the same message — primary already a duplicate — can never add
    // a second fee.
    final secondary = await _maybeSaveFee(
      rawMessage: rawMessage,
      primary: parsed,
      occurredAt: occurredAt,
      defaultAccount: defaultAccount,
      transactionTimeFromSms: transactionTimeFromSms,
      smsReceivedAt: receivedAt,
      comparisonTimestampSource: comparisonTimestampSource,
    );

    await _logMetric?.call('first_transaction_captured');
    return AddTransactionResult.added(
      saved,
      parseResult,
      isNewMerchant: isNewMerchant,
      secondary: secondary,
    );
  }

  Future<String?> _saveSuspectedDuplicate({
    required String rawMessage,
    required String? senderId,
    required String existingTransactionId,
    required ParsedTransaction parsed,
    required DateTime occurredAt,
    String? cardLast4,
    DateTime? comparisonTimestamp,
    ComparisonTimestampSource? comparisonTimestampSource,
    String? duplicateReason,
  }) async {
    final repo = _suspectedDuplicateRepository;
    if (repo == null) return null;
    final id = IdGenerator.next();
    await repo.save(SuspectedDuplicateEntity(
      id: id,
      rawMessage: rawMessage,
      senderId: senderId,
      existingTransactionId: existingTransactionId,
      amount: parsed.amount,
      currency: parsed.currency,
      rawMerchant: parsed.rawMerchant,
      occurredAt: occurredAt,
      cardLast4: cardLast4,
      comparisonTimestamp: comparisonTimestamp,
      comparisonTimestampSource: comparisonTimestampSource,
      duplicateReason: duplicateReason,
      createdAt: DateTime.now().toUtc(),
    ));
    return id;
  }

  Future<AccountEntity?> _existingAccountForCurrency(String currency) async {
    final repo = _accountRepository;
    final normalized = currency.trim().toUpperCase();
    if (repo == null || normalized.isEmpty) return null;
    final accounts = await repo.getAll();
    for (final account in accounts) {
      if (account.currency.trim().toUpperCase() == normalized) return account;
    }
    return null;
  }

  Future<AddTransactionResult?> _maybeSaveFee({
    required String rawMessage,
    required ParsedTransaction primary,
    required DateTime occurredAt,
    AccountEntity? defaultAccount,
    DateTime? transactionTimeFromSms,
    DateTime? smsReceivedAt,
    required ComparisonTimestampSource comparisonTimestampSource,
  }) async {
    final fee = _extractFeeAmount(rawMessage);
    if (fee == null) return null;
    final (amount, currency) = fee;
    // Same currency as the main amount → part of one charge, not a second
    // transaction; skip to avoid double counting.
    if (currency.toUpperCase() == primary.currency.trim().toUpperCase()) {
      return null;
    }

    Future<String> feeHash() => TransactionDedup.computeHash(
          amount: amount,
          currency: currency,
          cardLast4: primary.cardLast4,
          merchantNormalized: 'FEE',
          type: TransactionType.payment.name,
        );

    if (_dedupStore != null) {
      final existingId =
          await _dedupStore.transactionIdFor(await feeHash(), occurredAt);
      if (existingId != null) {
        final existing = await _transactionRepository.getById(existingId);
        if (existing != null) return AddTransactionResult.duplicate(existing);
      }
    }

    final account = await _accountForCurrency(
      _accountRepository,
      currency,
      fallback: defaultAccount,
    );
    final now = DateTime.now().toUtc();
    final feeTx = TransactionEntity(
      id: IdGenerator.next(),
      amount: amount,
      currency: currency,
      accountId: account?.id,
      merchantId: null,
      rawMerchant: null,
      categoryId: null,
      type: TransactionTypeEntity.payment,
      source: _mapSource(primary.source),
      cardLast4: primary.cardLast4,
      balanceAfter: null,
      note: 'رسوم/ضريبة',
      occurredAt: occurredAt.toUtc(),
      rawMessage: rawMessage,
      parseConfidence: 1.0,
      direction: TransactionDirectionEntity.debit,
      status: TransactionStatus.confirmed,
      createdAt: now,
      updatedAt: now,
      transactionTimeFromSms: transactionTimeFromSms,
      smsReceivedAt: smsReceivedAt,
      comparisonTimestamp: occurredAt.toUtc(),
      comparisonTimestampSource: comparisonTimestampSource,
      duplicateStatus: DuplicateStatus.normal,
    );
    final saved = await _transactionRepository.saveTransaction(
      transaction: feeTx,
      categoryKey: Categories.bills.key,
    );
    if (_dedupStore != null) {
      await _dedupStore.mark(
        await feeHash(),
        transactionId: feeTx.id,
        occurredAt: occurredAt,
      );
    }
    return AddTransactionResult.added(saved, ParseResult.notTransaction());
  }

  /// Extracts a fee/tax amount that appears AFTER a fee keyword
  /// (الرسوم/الضريبة/fee/VAT/tax). Returns null when no such line exists.
  static (double, String)? _extractFeeAmount(String rawMessage) {
    final keyword = RegExp(
      r'(?:الرسوم|الرسم|الضريبة|الضرائب|رسوم|ضريبة|fees?|vat|tax)',
      caseSensitive: false,
    ).firstMatch(rawMessage);
    if (keyword == null) return null;
    final fee = _extractAmountCurrency(rawMessage.substring(keyword.end));
    if (fee == null || fee.$1 <= 0) return null;
    return fee;
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

  Future<String> _effectiveInstallId() async {
    final cached = _installId;
    if (cached != null && cached.isNotEmpty) return cached;
    final loader = _loadInstallId;
    if (loader == null) return '';
    try {
      return await loader();
    } catch (_) {
      return '';
    }
  }

  Future<_AiFirstAttempt> _tryAiParseFirst({
    required String rawMessage,
    required String? senderId,
  }) async {
    if (_aiClient == null) return const _AiFirstAttempt.skipped('no_ai_client');
    final consent = await _loadAiConsent?.call() ?? false;
    if (!consent) return const _AiFirstAttempt.skipped('consent_off');
    final sid = senderId ?? '';
    if (AiSenderFailureTracker.instance.isSuppressed(sid)) {
      return const _AiFirstAttempt.skipped('sender_suppressed');
    }

    final sanitized = SmsSanitizer.sanitize(
      rawMessage,
      detectedType: _privacyTypeHint(rawMessage),
    );
    AiParseResponse? response;
    String? failureReason;
    try {
      response = await _aiClient.parse(
        sanitizedSms: sanitized,
        senderId: sid,
        installId: await _effectiveInstallId(),
      );
    } on AiParseException catch (error) {
      failureReason = error.reason;
    } catch (_) {
      failureReason = 'unexpected_ai_error';
    }
    return _AiFirstAttempt(
      senderId: sid,
      sanitizedSms: sanitized,
      response: response,
      failureReason: failureReason,
    );
  }

  _AppliedAiParse? _applyAiResponse({
    required _AiFirstAttempt attempt,
    required String rawMessage,
    required ParsedTransaction? localParsed,
  }) {
    final aiResponse = attempt.response;
    final sanitized = attempt.sanitizedSms;
    if (aiResponse == null || sanitized == null) return null;
    if (!GroundingCheck.verify(
      amount: aiResponse.amount,
      sanitizedText: sanitized,
    )) {
      AiSenderFailureTracker.instance.recordFailure(attempt.senderId);
      return null;
    }
    if (localParsed != null &&
        !_amountsClose(aiResponse.amount, localParsed.amount)) {
      AiSenderFailureTracker.instance.recordFailure(attempt.senderId);
      return null;
    }

    AiSenderFailureTracker.instance.recordSuccess(attempt.senderId);
    final aiType = _normalizeAiType(
      rawMessage: rawMessage,
      categoryKey: aiResponse.categoryKey,
      fallback: _parseTypeFromString(aiResponse.type) ??
          localParsed?.type ??
          TransactionType.unknown,
      merchantName: aiResponse.merchantName ?? localParsed?.rawMerchant,
    );
    final aiCategoryKey = aiResponse.categoryKey;
    final hasSpecificAiCategory =
        aiCategoryKey != null && aiCategoryKey != Categories.other.key;
    final aiTrusted = localParsed != null &&
        hasSpecificAiCategory &&
        !DirectionSignal.contradicts(rawMessage, aiType);

    return _AppliedAiParse(
      categoryKey: aiCategoryKey,
      direction: _parseAiDirection(aiResponse.direction),
      transaction: ParsedTransaction(
        amount: aiResponse.amount,
        currency: aiResponse.currency,
        type: aiType,
        source: TransactionSource.aiParsed,
        rawMerchant: PaymentAggregators.resolveMerchant(
              aiResponse.merchantName,
            ) ??
            localParsed?.rawMerchant,
        cardLast4: localParsed?.cardLast4,
        balanceAfter: localParsed?.balanceAfter,
        occurredAt: aiResponse.occurredAt ?? localParsed?.occurredAt,
        foreignAmount: localParsed?.foreignAmount,
        foreignCurrency: localParsed?.foreignCurrency,
        fundingSource: localParsed?.fundingSource,
        parseConfidence: aiTrusted ? 0.95 : 0.79,
      ),
    );
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

  static TransactionType _normalizeAiType({
    required String rawMessage,
    required String? categoryKey,
    required TransactionType fallback,
    String? merchantName,
  }) {
    final isTransferCategory = categoryKey == Categories.transfers.key;
    if (isTransferCategory || _looksLikeTransferMessage(rawMessage)) {
      return TransactionType.transfer;
    }
    if (categoryKey == Categories.cash.key &&
        fallback == TransactionType.payment &&
        _looksLikeBankAtmCardTransaction(
          rawMessage,
          merchantName: merchantName,
        )) {
      return TransactionType.withdrawal;
    }
    return fallback;
  }

  /// An explicit own-account / internal transfer: money the user moves between
  /// their own accounts. Neutral — excluded from both income and expense.
  /// Public: the backend capture import (CaptureSyncService) applies the same
  /// transfer accounting without going through this use case.
  static bool looksLikeInternalTransfer(String rawMessage) {
    final lower = rawMessage.toLowerCase();
    return lower.contains('internal transfer') ||
        lower.contains('own account') ||
        lower.contains('self transfer') ||
        lower.contains('between your accounts') ||
        lower.contains('تحويل داخلي') ||
        lower.contains('بين حساباتك') ||
        lower.contains('بين حساباتكم') ||
        lower.contains('لحسابك الآخر') ||
        lower.contains('من حسابك إلى حسابك');
  }

  static bool _looksLikeTransferMessage(String rawMessage) {
    final lower = rawMessage.toLowerCase();
    return lower.contains('ipn transfer') ||
        lower.contains('ipn ref') ||
        lower.contains('instapay') ||
        lower.contains('transfer sent') ||
        lower.contains('transfer received') ||
        lower.contains('outward transfer') ||
        lower.contains('inward transfer') ||
        lower.contains('internal transfer') ||
        (lower.contains('credited by') && lower.contains(' from ')) ||
        lower.contains('received from') ||
        lower.contains('sent to') ||
        (lower.contains('debited by') && lower.contains(' to ')) ||
        lower.contains('انستاباي') ||
        lower.contains('تحويل') ||
        lower.contains('حوالة');
  }

  static ParsedTransaction _replaceMerchant(
    ParsedTransaction transaction,
    String? rawMerchant,
  ) {
    return ParsedTransaction(
      amount: transaction.amount,
      currency: transaction.currency,
      type: transaction.type,
      source: transaction.source,
      rawMerchant: rawMerchant,
      cardLast4: transaction.cardLast4,
      balanceAfter: transaction.balanceAfter,
      occurredAt: transaction.occurredAt,
      foreignAmount: transaction.foreignAmount,
      foreignCurrency: transaction.foreignCurrency,
      fundingSource: transaction.fundingSource,
      parseConfidence: transaction.parseConfidence,
    );
  }

  static TransactionType? _privacyTypeHint(String rawMessage) {
    final lower = rawMessage.toLowerCase();
    final hasTransferWord = lower.contains('transfer') ||
        lower.contains('تحويل') ||
        lower.contains('حوالة');
    final hasPaymentWord = lower.contains('debit card') ||
        lower.contains('purchase') ||
        lower.contains('payment') ||
        lower.contains('successful transaction') ||
        lower.contains('transaction of') ||
        lower.contains('خصم') ||
        lower.contains('شراء') ||
        lower.contains('مشتريات') ||
        lower.contains('دفع');
    if (hasTransferWord) {
      return TransactionType.transfer;
    }
    if (lower.contains('salary') || lower.contains('راتب')) {
      return TransactionType.income;
    }
    if (hasPaymentWord) {
      return TransactionType.payment;
    }
    if (lower.contains('إلى') || lower.contains('الى')) {
      return TransactionType.transfer;
    }
    return null;
  }

  static ParsedTransaction? _lastResortParse(String rawMessage) {
    final amountCurrency = _extractAmountCurrency(rawMessage);
    if (amountCurrency == null) return null;
    final lower = rawMessage.toLowerCase();
    final merchant = _extractMerchantName(rawMessage);
    final direction = DirectionSignal.detect(rawMessage);
    final type = _lastResortType(
      lower: lower,
      direction: direction,
      merchantName: merchant,
    );

    return ParsedTransaction(
      amount: amountCurrency.$1,
      currency: amountCurrency.$2,
      type: type,
      source: TransactionSource.unknown,
      rawMerchant: merchant,
      occurredAt: _extractLooseArabicDateTime(rawMessage),
      parseConfidence: 0.55,
    );
  }

  static DateTime? _extractLooseArabicDateTime(String rawMessage) {
    final match = RegExp(
      r'(?:يوم|بتاريخ)\s+([0-9]{1,2})(?:[/-]([0-9]{1,2}))?(?:[/-]([0-9]{2,4}))?.{0,24}?(?:الساعة|الساعه|at)?\s*([0-9]{1,2}):([0-9]{2})',
      caseSensitive: false,
    ).firstMatch(rawMessage);
    if (match == null) return null;
    final now = DateTime.now();
    final day = int.parse(match.group(1)!);
    final month =
        match.group(2) == null ? now.month : int.parse(match.group(2)!);
    final rawYear = match.group(3);
    final year =
        rawYear == null ? now.year : _normalizeLooseYear(int.parse(rawYear));
    final hour = int.parse(match.group(4)!);
    final minute = int.parse(match.group(5)!);
    final parsed = DateTime(year, month, day, hour, minute);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return null;
    }
    if (rawYear == null && parsed.isAfter(now.add(const Duration(days: 1)))) {
      final previousMonth = month == 1 ? 12 : month - 1;
      final previousYear = month == 1 ? year - 1 : year;
      return DateTime(previousYear, previousMonth, day, hour, minute);
    }
    return parsed;
  }

  static int _normalizeLooseYear(int year) {
    if (year < 100) return 2000 + year;
    return year;
  }

  static (double, String)? _extractAmountCurrency(String rawMessage) {
    const codes = 'EGP|SAR|AED|USD|EUR|GBP|KWD|QAR|BHD|OMR|JOD';
    const aliases = 'جم|جنيه';
    final currencyBefore = RegExp(
      '\\b($codes)\\b\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)',
      caseSensitive: false,
    );
    final currencyAfter = RegExp(
      '([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*\\b($codes)\\b',
      caseSensitive: false,
    );
    final egyptianPoundAfter = RegExp(
      '([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*(?:$aliases)',
      caseSensitive: false,
    );
    final amountWord = RegExp(
      '(?:amount(?:\\s+of)?|مبلغ)\\s*(?:of\\s*)?\\b($codes)\\b\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)',
      caseSensitive: false,
    );

    final match = amountWord.firstMatch(rawMessage) ??
        currencyBefore.firstMatch(rawMessage);
    if (match != null) {
      final amount = double.tryParse(match.group(2)!.replaceAll(',', ''));
      if (amount == null) return null;
      return (amount, match.group(1)!.toUpperCase());
    }

    final reverse = currencyAfter.firstMatch(rawMessage);
    if (reverse != null) {
      final amount = double.tryParse(reverse.group(1)!.replaceAll(',', ''));
      if (amount == null) return null;
      return (amount, reverse.group(2)!.toUpperCase());
    }
    final egp = egyptianPoundAfter.firstMatch(rawMessage);
    if (egp != null) {
      final amount = double.tryParse(egp.group(1)!.replaceAll(',', ''));
      if (amount == null) return null;
      return (amount, 'EGP');
    }
    return null;
  }

  static String? _extractMerchantName(String rawMessage) {
    final match = RegExp(
      r'(?:@|\bat\b)\s*([^,.;\n]+)',
      caseSensitive: false,
    ).firstMatch(rawMessage);
    final merchant = match?.group(1);
    if (merchant == null) return null;
    final cleaned = merchant
        .replaceFirst(RegExp(r'\s+\bon\b.+$', caseSensitive: false), '')
        .replaceFirst(RegExp(r'\s+\d{1,2}[/-]\d{1,2}.*$'), '')
        .replaceFirst(
            RegExp(r'\s+\bat\b\s*\d{1,2}:\d{2}.*$', caseSensitive: false), '')
        .replaceAll(RegExp(r'[.;،]+$'), '')
        .trim();
    return cleaned.isEmpty ? null : cleaned;
  }

  static TransactionType _lastResortType({
    required String lower,
    required TxnDirection? direction,
    required String? merchantName,
  }) {
    if (lower.contains('ipn transfer') ||
        lower.contains('transfer') ||
        lower.contains('تحويل') ||
        lower.contains('حوالة')) {
      return TransactionType.transfer;
    }
    if (BankProfiles.detect('', senderId: merchantName ?? '') != null ||
        lower.contains('atm') ||
        lower.contains('cash withdrawal') ||
        lower.contains('سحب')) {
      return TransactionType.withdrawal;
    }
    if (direction == TxnDirection.credit &&
        (lower.contains('salary') || lower.contains('راتب'))) {
      return TransactionType.income;
    }
    return TransactionType.payment;
  }

  static String _bestEffortMerchantCategory(String merchantName) {
    final upper = merchantName.toUpperCase();
    bool hasAny(Iterable<String> needles) =>
        needles.any((needle) => upper.contains(needle));

    if (hasAny(const [
      'CAFE',
      'COFFEE',
      'ESPRESSO',
      'BAKERY',
      'PATISSERIE',
      'كافيه',
      'قهوة',
      'مخبز',
    ])) {
      return Categories.cafes.key;
    }
    if (hasAny(const [
      'RESTAURANT',
      'REST',
      'BURGER',
      'PIZZA',
      'CHICKEN',
      'GRILL',
      'KITCHEN',
      'FOOD',
      'مطعم',
      'بيتزا',
      'برجر',
      'مشويات',
    ])) {
      return Categories.restaurants.key;
    }
    if (hasAny(const [
      'MARKET',
      'MART',
      'GROCERY',
      'SUPERMARKET',
      'HYPER',
      'BAQALA',
      'بقالة',
      'سوبر',
      'ماركت',
    ])) {
      return Categories.groceries.key;
    }
    if (hasAny(const [
      'PHARMACY',
      'PHARMA',
      'CLINIC',
      'HOSPITAL',
      'MEDICAL',
      'صيدلية',
      'عيادة',
      'مستشفى',
    ])) {
      return Categories.health.key;
    }
    if (hasAny(const [
      'PETROL',
      'FUEL',
      'GAS',
      'STATION',
      'بنزين',
      'وقود',
    ])) {
      return Categories.fuel.key;
    }
    if (hasAny(const [
      'UBER',
      'CAREEM',
      'TAXI',
      'BUS',
      'METRO',
      'TRAIN',
      'TRANSPORT',
      'تاكسي',
      'مترو',
      'مواصلات',
    ])) {
      return Categories.transport.key;
    }
    if (hasAny(const [
      'TELECOM',
      'MOBILE',
      'INTERNET',
      'ELECTRIC',
      'WATER',
      'UTILITY',
      'فاتورة',
      'كهرباء',
      'مياه',
      'انترنت',
    ])) {
      return Categories.bills.key;
    }
    if (hasAny(const ['GYM', 'FITNESS', 'SPORT', 'نادي', 'جيم'])) {
      return Categories.fitness.key;
    }
    if (hasAny(const ['SALON', 'BEAUTY', 'BARBER', 'SPA', 'صالون', 'حلاق'])) {
      return Categories.beauty.key;
    }
    if (hasAny(const [
      'HOTEL',
      'AIR',
      'TRAVEL',
      'FLIGHT',
      'TOUR',
      'فندق',
      'طيران',
      'سفر',
    ])) {
      return Categories.travel.key;
    }
    if (hasAny(const ['CINEMA', 'MOVIE', 'GAME', 'PLAY', 'سينما', 'العاب'])) {
      return Categories.entertainment.key;
    }
    return Categories.shopping.key;
  }

  static bool _looksLikeBankAtmCardTransaction(
    String rawMessage, {
    required String? merchantName,
  }) {
    if (merchantName == null || merchantName.trim().isEmpty) return false;
    final lower = rawMessage.toLowerCase();
    final hasDebitCard = lower.contains('debit card');
    final hasGenericTransaction = lower.contains('successful transaction') ||
        lower.contains('transaction of');
    if (!hasDebitCard || !hasGenericTransaction) return false;
    return BankProfiles.detect('', senderId: merchantName) != null;
  }

  static bool _amountsClose(double left, double right) {
    return (left - right).abs() < 0.01;
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

  static String? _dedupFingerprint(
    ParsedTransaction transaction, {
    required String rawMessage,
  }) {
    if (transaction.type != TransactionType.transfer) {
      return transaction.rawMerchant == null
          ? null
          : TransactionDedup.normalizeMerchant(transaction.rawMerchant!);
    }
    final reference = RegExp(
      r'(?:ref(?:erence)?#?|رقم\s*مرجعي)\s*:?\s*([A-Za-z0-9]+)',
      caseSensitive: false,
    ).firstMatch(rawMessage);
    if (reference != null) {
      return 'TRANSFER_REF_${reference.group(1)!.toUpperCase()}';
    }
    return 'TRANSFER_MSG_${TransactionDedup.normalizeMerchant(rawMessage)}';
  }

  static TransactionDirectionEntity? _parseAiDirection(String? raw) {
    return switch (raw) {
      'credit' => TransactionDirectionEntity.credit,
      'debit' => TransactionDirectionEntity.debit,
      'unknown' => TransactionDirectionEntity.unknown,
      _ => null,
    };
  }

  static TransactionDirectionEntity? _directionFromText(String rawMessage) {
    return switch (DirectionSignal.detect(rawMessage)) {
      TxnDirection.credit => TransactionDirectionEntity.credit,
      TxnDirection.debit => TransactionDirectionEntity.debit,
      TxnDirection.unknown => null,
    };
  }

  static TransactionDirectionEntity _directionFromType(TransactionType type) {
    return switch (DirectionSignal.ofType(type)) {
      TxnDirection.credit => TransactionDirectionEntity.credit,
      TxnDirection.debit => TransactionDirectionEntity.debit,
      TxnDirection.unknown => TransactionDirectionEntity.unknown,
    };
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
    AccountRepository? accountRepository,
    SuspectedDuplicateRepository? suspectedDuplicateRepository,
  })  : _transactionRepository = transactionRepository,
        _recordEngagementUseCase = recordEngagementUseCase,
        _logMetric = logMetric,
        _accountRepository = accountRepository,
        _suspectedDuplicateRepository = suspectedDuplicateRepository;

  final TransactionRepository _transactionRepository;
  final RecordEngagementUseCase? _recordEngagementUseCase;
  final Future<void> Function(String key, {String? dimension})? _logMetric;
  final AccountRepository? _accountRepository;
  final SuspectedDuplicateRepository? _suspectedDuplicateRepository;

  Future<TransactionEntity> call({
    required double amount,
    required String currency,
    required TransactionTypeEntity type,
    required DateTime occurredAt,
    required String categoryKey,
    String? merchant,
    String? note,
    String? accountId,
    String? cardLast4,
  }) async {
    final now = DateTime.now().toUtc();
    final normalizedCurrency = currency.trim().toUpperCase();
    final normalizedMerchant = merchant?.trim();
    final normalizedNote = note?.trim();
    final comparisonTimestamp = occurredAt.toUtc();
    final description = normalizedMerchant == null || normalizedMerchant.isEmpty
        ? (normalizedNote == null || normalizedNote.isEmpty
            ? 'Manual transaction'
            : normalizedNote)
        : normalizedMerchant;
    final possibleDuplicate =
        await _transactionRepository.findSuspiciousDuplicate(
      amount: amount,
      currency: normalizedCurrency,
      merchantOrDescription: description,
      cardLast4: cardLast4,
      comparisonTimestamp: comparisonTimestamp,
    );
    if (possibleDuplicate != null && _suspectedDuplicateRepository != null) {
      final rawMessage = _manualRawMessage(
        amount: amount,
        currency: normalizedCurrency,
        merchant: normalizedMerchant,
        note: normalizedNote,
        occurredAt: comparisonTimestamp,
      );
      await _suspectedDuplicateRepository.save(SuspectedDuplicateEntity(
        id: IdGenerator.next(),
        rawMessage: rawMessage,
        senderId: null,
        existingTransactionId: possibleDuplicate.id,
        amount: amount,
        currency: normalizedCurrency,
        rawMerchant: normalizedMerchant,
        occurredAt: comparisonTimestamp,
        cardLast4: cardLast4,
        comparisonTimestamp: comparisonTimestamp,
        comparisonTimestampSource: ComparisonTimestampSource.receivedAt,
        duplicateReason:
            'same amount, currency, merchant and manual comparison time',
        createdAt: now,
      ));
      return possibleDuplicate;
    }
    final effectiveAccount = accountId == null
        ? await _accountForCurrency(_accountRepository, normalizedCurrency)
        : null;
    final transaction = TransactionEntity(
      id: IdGenerator.next(),
      amount: amount,
      currency: normalizedCurrency,
      accountId: accountId ?? effectiveAccount?.id,
      merchantId: null,
      rawMerchant: normalizedMerchant == null || normalizedMerchant.isEmpty
          ? null
          : normalizedMerchant,
      categoryId: null,
      type: type,
      source: TransactionSourceEntity.unknown,
      cardLast4: (cardLast4 == null || cardLast4.isEmpty) ? null : cardLast4,
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
      smsReceivedAt: now,
      comparisonTimestamp: comparisonTimestamp,
      comparisonTimestampSource: ComparisonTimestampSource.receivedAt,
      duplicateStatus: DuplicateStatus.normal,
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

  String _manualRawMessage({
    required double amount,
    required String currency,
    required String? merchant,
    required String? note,
    required DateTime occurredAt,
  }) {
    final buffer = StringBuffer()
      ..writeln('Manual transaction')
      ..writeln('مبلغ:$currency ${amount.toStringAsFixed(2)}');
    if (merchant != null && merchant.isNotEmpty) {
      buffer.writeln('لدى:$merchant');
    }
    if (note != null && note.isNotEmpty) {
      buffer.writeln('ملاحظة:$note');
    }
    buffer.writeln('في:${occurredAt.toIso8601String().substring(0, 16)}');
    return buffer.toString().trim();
  }
}
