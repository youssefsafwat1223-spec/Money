import '../../engine/ai/bank_discovery_client.dart';
import '../../engine/models/transaction_type.dart';
import '../../engine/parser/bank_profile.dart';
import '../../engine/parser/bank_sender_filter.dart';
import '../../engine/parser/parse_result.dart';
import '../../engine/parser/parser_engine.dart';
import '../../engine/privacy/sms_sanitizer.dart';
import '../entities/bank_discovery_models.dart';
import '../entities/sender_bank_mapping_entity.dart';
import '../repositories/sender_bank_mapping_repository.dart';

class BankDiscoveryService {
  const BankDiscoveryService({
    required SenderBankMappingRepository mappingRepository,
    required BankDiscoveryClient client,
    required Future<bool> Function() loadAiConsent,
    this.loadInstallId,
    this.confidenceThreshold = 0.95,
    this.rateLimitAllowsDiscovery,
  })  : _mappingRepository = mappingRepository,
        _client = client,
        _loadAiConsent = loadAiConsent;

  final SenderBankMappingRepository _mappingRepository;
  final BankDiscoveryClient _client;
  final Future<bool> Function() _loadAiConsent;
  final double confidenceThreshold;
  final Future<bool> Function(String senderId)? rateLimitAllowsDiscovery;

  /// Sent to the backend so it can cap discovery calls per install — the
  /// server-side rate limit is the one that actually matters (it also gates
  /// direct API callers using just the public anon key), this is optional
  /// only so a caller that has no install id yet doesn't fail discovery.
  final Future<String> Function()? loadInstallId;

  Future<BankDiscoveryResult> discoverIfEligible({
    required String rawSms,
    required String? senderId,
    required List<BankProfile> availableProfiles,
    required ParseResult parseResult,
    String? localeHint,
    DateTime? now,
  }) async {
    final cleanSender = senderId?.trim();
    if (cleanSender == null || cleanSender.isEmpty) {
      return const BankDiscoveryResult.ineligible('missing_sender');
    }

    if (parseResult.isTransaction &&
        parseResult.confidence >= ParserEngine.pendingThreshold) {
      return const BankDiscoveryResult.skipped('generic_pending_is_usable');
    }

    if (!BankSenderFilter.isLikelyBank(cleanSender, text: rawSms)) {
      return const BankDiscoveryResult.ineligible('sender_not_bank_like');
    }

    if (ParserEngine.isIgnoredMessage(
      rawSms,
      senderId: cleanSender,
      bankProfiles: availableProfiles,
    )) {
      return const BankDiscoveryResult.ineligible('ignored_message');
    }

    final knownProfile = BankProfiles.detect(
      rawSms,
      senderId: cleanSender,
      extraProfiles: availableProfiles,
    );
    if (knownProfile != null) {
      return const BankDiscoveryResult.skipped('known_bank_profile');
    }

    final mapping = await _mappingRepository.getBySender(cleanSender);
    if (mapping?.status == SenderBankMappingStatus.confirmed) {
      return const BankDiscoveryResult.skipped('confirmed_mapping');
    }
    if (mapping?.status == SenderBankMappingStatus.rejected &&
        mapping!.suppressesDiscovery(now ?? DateTime.now().toUtc())) {
      return const BankDiscoveryResult.skipped('rejected_cooldown');
    }
    if (mapping?.status == SenderBankMappingStatus.pending) {
      return const BankDiscoveryResult.skipped('pending_mapping_exists');
    }

    final consent = await _loadAiConsent();
    if (!consent) {
      return const BankDiscoveryResult.ineligible('ai_consent_required');
    }

    final limiter = rateLimitAllowsDiscovery;
    if (limiter != null && !await limiter(cleanSender)) {
      return const BankDiscoveryResult.skipped('rate_limited');
    }

    final request = BankDiscoveryRequest(
      senderId: cleanSender,
      sanitizedSms: SmsSanitizer.sanitize(
        rawSms,
        detectedType: parseResult.transaction?.type ?? _guessType(rawSms),
      ),
      detectedCurrency:
          parseResult.transaction?.currency ?? _detectCurrency(rawSms),
      localeHint: localeHint,
      installId: await loadInstallId?.call(),
    );
    final suggestion = await _client.detectBank(request);
    if (suggestion == null) {
      return const BankDiscoveryResult.noSuggestion('client_returned_null');
    }
    if (suggestion.confidence < confidenceThreshold) {
      return const BankDiscoveryResult.noSuggestion('low_confidence');
    }

    await _mappingRepository.saveSuggestion(SenderBankMappingDraft(
      senderId: cleanSender,
      bankKey: suggestion.bankKeySuggestion,
      suggestedBankName: suggestion.suggestedBankName,
      suggestedCountry: suggestion.country,
      confidence: suggestion.confidence,
      reason: suggestion.reason,
      source: SenderBankMappingSource.gemini,
      now: now,
    ));
    return BankDiscoveryResult.pendingSuggestion(suggestion);
  }

  static final RegExp _currency = RegExp(
    r'\b(SAR|AED|EGP|KWD|QAR|BHD|OMR|USD|EUR|GBP|TRY|INR|PKR|CAD|AUD|JPY|CNY|CHF|MAD|DZD|TND|JOD|IQD|LBP)\b',
    caseSensitive: false,
  );

  String? _detectCurrency(String rawSms) {
    final match = _currency.firstMatch(rawSms);
    return match?.group(1)?.toUpperCase();
  }

  TransactionType? _guessType(String rawSms) {
    final lower = rawSms.toLowerCase();
    if (lower.contains('transfer') ||
        lower.contains('تحويل') ||
        lower.contains('حوالة')) {
      return TransactionType.transfer;
    }
    if (lower.contains('salary') ||
        lower.contains('deposit') ||
        lower.contains('إيداع') ||
        lower.contains('ايداع')) {
      return TransactionType.income;
    }
    if (lower.contains('purchase') ||
        lower.contains('payment') ||
        lower.contains('trx') ||
        lower.contains('شراء') ||
        lower.contains('دفع')) {
      return TransactionType.payment;
    }
    return null;
  }
}
