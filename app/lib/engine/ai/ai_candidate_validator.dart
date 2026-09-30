import '../models/parsed_transaction.dart';
import '../parser/normalizer.dart';
import 'ai_parser_client.dart';
import 'grounding_check.dart';

/// Outcome of [AiCandidateValidator.validate]. When [accepted] is false the AI
/// candidate must be discarded entirely.
class AiCandidateValidation {
  const AiCandidateValidation.rejected(this.rejectionReason)
      : accepted = false,
        currency = '',
        merchantName = null,
        occurredAt = null;

  const AiCandidateValidation.accepted({
    required this.currency,
    required this.merchantName,
    required this.occurredAt,
  })  : accepted = true,
        rejectionReason = null;

  final bool accepted;
  final String? rejectionReason;

  /// Upper-cased, validated currency (empty when rejected).
  final String currency;

  /// The AI merchant when grounded in the text, else the local one (or null).
  final String? merchantName;

  /// The AI date when inside the plausibility window, else the local one.
  final DateTime? occurredAt;
}

/// Deterministic, side-effect-free gate for an AI parse candidate. It never
/// reads anything that resembles an AI confidence: the tier is decided by the
/// caller from local agreement alone.
class AiCandidateValidator {
  const AiCandidateValidator({DateTime Function()? clock}) : _clock = clock;

  final DateTime Function()? _clock;

  static const Duration _maxAge = Duration(days: 31);
  static const Duration _maxFuture = Duration(days: 1);

  /// Currency spellings beyond what [Normalizer.normalizeCurrencyTokens]
  /// already maps to an ISO code.
  static const Map<String, List<String>> _extraAliases = {
    'USD': [r'$'],
    'EUR': ['€'],
    'GBP': ['£'],
    'JOD': ['دينار أردني', 'دينار اردني'],
  };

  AiCandidateValidation validate({
    required AiParseResponse response,
    required String sanitizedText,
    required ParsedTransaction? localParsed,
    DateTime? referenceTime,
  }) {
    if (!GroundingCheck.verify(
      amount: response.amount,
      sanitizedText: sanitizedText,
    )) {
      return const AiCandidateValidation.rejected('amount_not_grounded');
    }
    final currency = response.currency.trim().toUpperCase();
    if (localParsed != null) {
      if (!((response.amount - localParsed.amount).abs() < 0.01)) {
        return const AiCandidateValidation.rejected('amount_mismatch_local');
      }
      if (currency != localParsed.currency.trim().toUpperCase()) {
        return const AiCandidateValidation.rejected('currency_mismatch_local');
      }
    } else if (!_currencyGrounded(currency, sanitizedText)) {
      return const AiCandidateValidation.rejected('currency_not_grounded');
    }

    final merchant = _merchantGrounded(response.merchantName, sanitizedText)
        ? response.merchantName
        : localParsed?.rawMerchant;

    final reference = (referenceTime ?? _clock?.call() ?? DateTime.now());
    final aiDate = response.occurredAt;
    final dateOk = aiDate != null &&
        !aiDate.isBefore(reference.subtract(_maxAge)) &&
        !aiDate.isAfter(reference.add(_maxFuture));

    return AiCandidateValidation.accepted(
      currency: currency,
      merchantName: merchant,
      occurredAt: dateOk ? aiDate : localParsed?.occurredAt,
    );
  }

  static bool _currencyGrounded(String iso, String text) {
    if (iso.isEmpty) return false;
    final normalized = Normalizer.normalizeCurrencyTokens(text);
    final code = RegExp(
      '(?<![A-Za-z])${RegExp.escape(iso)}(?![A-Za-z])',
      caseSensitive: false,
    );
    if (code.hasMatch(normalized)) return true;
    final extras = _extraAliases[iso] ?? const <String>[];
    return extras.any(text.contains);
  }

  static bool _merchantGrounded(String? merchant, String text) {
    if (merchant == null) return false;
    final needle = _collapse(merchant);
    if (needle.isEmpty) return false;
    return _collapse(text).contains(needle);
  }

  static String _collapse(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}
