import 'normalizer.dart';

/// F-016 — the catalog parser rule as the DEVICE runtime authority.
///
/// Until this module existed, `sender_pattern`, `message_pattern` and
/// `priority` were compiled only to validate syntax and then discarded — a
/// rule's presence was converted into generic keyword hints, so Admin edits to
/// the patterns had zero behavioural effect on the device. This module gives
/// the catalog its intended matching semantics, identical to the contract the
/// admin Parser Lab / `parser-test` edge function already exercise:
///
///   * a rule is ELIGIBLE only when `sender_pattern` matches the sender id
///     AND `message_pattern` matches the message text;
///   * among eligible rules, `priority` (higher first, then rule id for a
///     total order) deterministically picks ONE winner;
///   * the winner's named capture groups (`(?<amount>…)` …), routed through
///     `extracted_fields`, provide the extracted values;
///   * an invalid regex fails CLOSED — the rule is skipped, never guessed at;
///   * a non-matching rule has zero behavioural effect.
///
/// Execution stays bounded: matching runs inside the parser isolate's
/// 2-second timeout like every other engine path, and rule/message sizes are
/// capped below as an explicit belt against pathological catalog input.
class CatalogParserRule {
  const CatalogParserRule({
    required this.id,
    required this.senderPattern,
    required this.messagePattern,
    required this.transactionType,
    required this.priority,
    this.extractedFields = const {},
  });

  final String id;
  final String senderPattern;
  final String messagePattern;

  /// The catalog column: 'debit' | 'credit' | 'balance_inquiry'.
  final String transactionType;
  final int priority;

  /// `{"type": "debit", "amount": "amount", "merchant": "merchant", …}` —
  /// field name → capture-group name ('type' maps to a literal value instead).
  final Map<String, Object?> extractedFields;
}

/// The values a matched rule actually produced. Absent fields (group not
/// declared, or declared but unmatched in this message) stay null — the engine
/// falls back to its own extraction for those, never for present ones.
class CatalogRuleMatch {
  const CatalogRuleMatch({
    required this.rule,
    this.amountText,
    this.currencyText,
    this.merchant,
    this.balanceText,
  });

  final CatalogParserRule rule;
  final String? amountText;
  final String? currencyText;
  final String? merchant;
  final String? balanceText;
}

/// Explicit caps — a catalog row cannot make the device execute unbounded
/// input even before the isolate timeout kicks in.
const int kMaxCatalogPatternLength = 2000;
const int kMaxCatalogMessageLength = 4000;

/// Deterministically resolves the winning rule for (sender, message), or null.
///
/// Order: priority DESC, then id ASC — a total order, so equal-priority
/// collisions cannot flip between runs. The first ELIGIBLE rule wins.
CatalogRuleMatch? matchCatalogRule(
  List<CatalogParserRule> rules, {
  required String? senderId,
  required String messageText,
}) {
  if (rules.isEmpty || senderId == null || senderId.isEmpty) return null;
  if (messageText.length > kMaxCatalogMessageLength) return null;

  final ordered = [...rules]..sort((a, b) {
      final byPriority = b.priority.compareTo(a.priority);
      return byPriority != 0 ? byPriority : a.id.compareTo(b.id);
    });

  for (final rule in ordered) {
    if (rule.senderPattern.length > kMaxCatalogPatternLength ||
        rule.messagePattern.length > kMaxCatalogPatternLength) {
      continue; // fail closed
    }
    final RegExp senderRe;
    final RegExp messageRe;
    try {
      senderRe = RegExp(rule.senderPattern, caseSensitive: false);
      messageRe = RegExp(rule.messagePattern, caseSensitive: false);
    } on FormatException {
      continue; // fail closed — an invalid rule can never match
    }
    if (!senderRe.hasMatch(senderId)) continue;
    final m = messageRe.firstMatch(messageText);
    if (m == null) continue;

    String? group(String field) {
      final groupName = rule.extractedFields[field];
      if (groupName is! String || groupName.isEmpty) return null;
      String? value;
      try {
        value = m.namedGroup(groupName);
      } on ArgumentError {
        return null; // declared group does not exist in the pattern
      }
      final trimmed = value?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    }

    return CatalogRuleMatch(
      rule: rule,
      amountText: group('amount'),
      currencyText: group('currency'),
      merchant: group('merchant'),
      balanceText: group('balance'),
    );
  }
  return null;
}

/// Parses a rule-captured amount text exactly like admin-authored rules expect
/// (`1,234.56`, Arabic-digit variants). Null when it cannot be parsed — the
/// engine's own extraction then takes over.
double? parseCatalogAmount(String? text) {
  if (text == null) return null;
  final normalized =
      Normalizer.normalize(text).replaceAll(',', '').replaceAll(' ', '');
  final value = double.tryParse(normalized);
  return (value == null || value <= 0) ? null : value;
}

/// Maps a rule-captured currency token to an ISO code via the same alias
/// normalisation the engine applies to message text. Null when the token does
/// not resolve — the engine currency detection then takes over.
String? parseCatalogCurrency(String? token) {
  if (token == null) return null;
  final normalized = Normalizer.normalizeCurrencyTokens(
    Normalizer.normalize(token),
  ).trim();
  final iso = RegExp(r'^[A-Za-z]{3}$');
  if (iso.hasMatch(normalized)) return normalized.toUpperCase();
  // Common Arabic tokens that the shared normaliser leaves bare.
  const aliases = {
    'ريال': 'SAR',
    'جنيه': 'EGP',
    'درهم': 'AED',
    'دينار': 'KWD',
  };
  return aliases[normalized];
}
