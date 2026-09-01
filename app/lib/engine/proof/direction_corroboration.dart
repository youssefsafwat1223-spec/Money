/// Deterministic direction corroboration — D1, D2 and D3.
///
/// ## Why direction needs corroboration at all
///
/// The rev-2 baseline auto-committed nine credit-card repayment messages as
/// INCOMING against gold OUTGOING. The model was confident, the amount was a
/// real token of the message, and nothing independent was ever asked to agree.
/// Confidence is not evidence. A direction may only be proven when a
/// DETERMINISTIC source, computed before the model ran, says the same thing.
///
/// ## The four sources, and what each may do
///
///   D1  explicit lexical polarity in the message           may corroborate
///   D2  bank-profile rule with deterministic polarity      may corroborate
///   D3  catalog rule with deterministic polarity           may corroborate
///   D4  account/card context                               DIAGNOSTIC ONLY
///
/// D4 is deliberately absent from this file. It may not corroborate and it may
/// not resolve a conflict between the others, so an implementation that cannot
/// express it cannot misuse it.
///
/// ## The circularity ban
///
/// Nothing here may read the AI's proposal. D2 and D3 derive polarity from
/// rules that matched the raw message text before any model call, and the
/// mapping from rule-type to polarity is PREDECLARED below. The AI's own
/// `type` may never vouch for the AI's own `direction`, and neither may a
/// post-AI `_mapType`: both would be the model agreeing with itself.
///
/// ## Provenance
///
/// Every corroborator carries the rule that produced it, so the checker can
/// state exactly which bank profile or catalog rule supplied a direction
/// rather than asserting that something, somewhere, agreed.
library;

import '../models/transaction_type.dart';
import '../parser/bank_profile.dart';
import '../parser/catalog_rule_matcher.dart';
import 'evidence.dart';

/// Which deterministic layer produced a corroborator.
enum CorroborationSource {
  d1Lexical,
  d2BankProfile,
  d3CatalogRule;

  String get wire => switch (this) {
        CorroborationSource.d1Lexical => 'D1',
        CorroborationSource.d2BankProfile => 'D2',
        CorroborationSource.d3CatalogRule => 'D3',
      };
}

/// Transaction types whose direction is UNAMBIGUOUS, and may therefore be read
/// as polarity by D2/D3.
///
/// This map is the whole of the "predeclared deterministic type→direction
/// mapping". A type is present only if money can move in exactly one direction
/// for it, from the account holder's point of view.
///
/// Deliberately ABSENT, and why:
///   transfer           — direction-neutral by construction. A transfer may be
///                        either leg and the message often does not say which.
///                        This is the single most important exclusion here.
///   creditCardPayment  — Phase 0-A approved `transfer` accounting semantics
///                        for it, and it is a review-only family regardless, so
///                        letting it corroborate would buy no coverage while
///                        asserting a polarity the accounting model disputes.
///   unknown            — carries no meaning to map.
const Map<TransactionType, DirectionCuePolarity> kDeterministicTypePolarity = {
  TransactionType.payment: DirectionCuePolarity.outgoing,
  TransactionType.withdrawal: DirectionCuePolarity.outgoing,
  TransactionType.governmentPayment: DirectionCuePolarity.outgoing,
  TransactionType.refund: DirectionCuePolarity.incoming,
  TransactionType.income: DirectionCuePolarity.incoming,
};

/// A REVERSAL WRAPPER and the span of message it governs.
///
/// `عكس عملية شراء بمبلغ 320.50` is a refund, not a purchase. The purchase verb
/// is still present and still says "outgoing" — but it is the verb of the event
/// being UNDONE, not of the event being reported. Reading it unwrapped is how
/// the Gemini Phase-5 run produced its only false auto-commit: D1 voted
/// outgoing on `شراء`, a catalog rule voted outgoing on `payment`, the model
/// agreed with both, and a refund was booked as a spend.
class _ReversalScope {
  const _ReversalScope(
      this.start, this.end, this.marker, this.markerStart, this.markerEnd);

  /// The clause the wrapper governs.
  final int start;
  final int end;
  final String marker;

  /// The wrapper phrase's own span.
  final int markerStart;
  final int markerEnd;

  bool covers(int spanStart) => spanStart >= start && spanStart < end;

  /// True when [spanStart] falls inside the WRAPPER PHRASE itself.
  ///
  /// Several wrappers are also credit cues in their own right — `عكس قيد`,
  /// `reversed` — because a reversal IS money coming back. Such a cue must
  /// keep its polarity rather than be inverted by the very wrapper it forms:
  /// inverting it would cancel the correct vote and turn a clear refund into a
  /// direction conflict.
  bool isMarkerItself(int spanStart) =>
      spanStart >= markerStart && spanStart < markerEnd;
}

/// Conservative reversal markers. PHRASE-scoped for Arabic, because the bare
/// stem `عكس` occurs in `بالعكس`, `عكسية` and `انعكاس`, where it carries no
/// transactional meaning at all.
const List<String> _reversalMarkers = [
  'عكس عملية', 'عكس العملية', 'عكس قيد', 'عكس الحركة', 'عكس حركة',
  'إلغاء عملية', 'الغاء عملية', 'إلغاء العملية', 'الغاء العملية',
  'reversal of', 'reversal', 'reversed', 'has been reversed',
];

/// Clause delimiters. A wrapper governs its OWN clause, never the whole
/// message: a reversal in one line must not invert a separate transaction
/// reported on the next.
const List<String> _clauseBreaks = ['\n', '.', '،', '؛', ';', '|'];

List<_ReversalScope> _reversalScopes(String lower) {
  final out = <_ReversalScope>[];
  for (final m in _reversalMarkers) {
    final needle = m.toLowerCase();
    var from = 0;
    while (true) {
      final i = lower.indexOf(needle, from);
      if (i < 0) break;
      from = i + 1;
      final markerEnd = i + needle.length;
      // Latin markers must be whole words; `reversal` must not fire inside a
      // longer token.
      if (RegExp(r'^[a-z ]+$').hasMatch(needle)) {
        final before = i > 0 ? lower[i - 1] : ' ';
        final after = markerEnd < lower.length ? lower[markerEnd] : ' ';
        if (RegExp('[a-z0-9]').hasMatch(before) ||
            RegExp('[a-z0-9]').hasMatch(after)) {
          continue;
        }
      }
      // Scope is the CLAUSE CONTAINING the marker, not merely the text after
      // it. `purchase reversed AED 100` puts the wrapper AFTER the verb it
      // undoes, so a forward-only scope would leave `purchase` voting
      // outgoing and produce a conflict on a perfectly clear refund.
      var start = 0;
      for (final b in _clauseBreaks) {
        final j = lower.lastIndexOf(b, i);
        if (j >= 0 && j + 1 > start) start = j + 1;
      }
      var end = lower.length;
      for (final b in _clauseBreaks) {
        final j = lower.indexOf(b, markerEnd);
        if (j >= 0 && j < end) end = j;
      }
      out.add(_ReversalScope(start, end, m, i, markerEnd));
    }
  }
  return out;
}

/// One deterministic vote for a direction, with the reason it exists.
class DirectionCorroborator {
  const DirectionCorroborator({
    required this.source,
    required this.polarity,
    required this.provenance,
  });

  final CorroborationSource source;
  final DirectionCuePolarity polarity;

  /// Human-readable and machine-stable, e.g.
  /// `D2 bank:alrajhi typeRule:withdrawal("سحب")` or `D3 catalog:rule_7 type=debit`.
  final String provenance;

  @override
  String toString() => '${source.wire}:${polarity.name}($provenance)';
}

/// Every deterministic corroborator available for this message.
///
/// [bank] and [catalogMatch] are the PRE-AI deterministic parser's own
/// findings. Passing null for either simply removes that source; it never
/// weakens the gate, because a missing corroborator can only make the outcome
/// more conservative.
List<DirectionCorroborator> deterministicCorroborators({
  required String sms,
  required EvidenceSet evidence,
  BankProfile? bank,
  CatalogParserRule? catalogRule,
}) {
  final out = <DirectionCorroborator>[];
  final lower = sms.toLowerCase();
  final scopes = _reversalScopes(lower);
  final reversalPresent = scopes.isNotEmpty;

  DirectionCuePolarity invert(DirectionCuePolarity p) =>
      p == DirectionCuePolarity.incoming
          ? DirectionCuePolarity.outgoing
          : DirectionCuePolarity.incoming;

  // ---- D1: explicit lexical polarity ------------------------------------
  for (final cue in evidence.ofClass(EvidenceClass.directionCue)) {
    final p = cue.directionPolarity;
    if (p == null) continue;
    _ReversalScope? wrap;
    for (final s in scopes) {
      if (s.covers(cue.start) && !s.isMarkerItself(cue.start)) {
        wrap = s;
        break;
      }
    }
    if (wrap == null) {
      out.add(DirectionCorroborator(
        source: CorroborationSource.d1Lexical,
        polarity: p,
        provenance: 'D1 cue:"${cue.text}"@${cue.start}',
      ));
    } else {
      // WRAPPED: the inverted polarity REPLACES the base vote. The unwrapped
      // vote is never also emitted — a reversal produces one authority, not
      // two contradictory ones.
      out.add(DirectionCorroborator(
        source: CorroborationSource.d1Lexical,
        polarity: invert(p),
        provenance: 'D1 cue:"${cue.text}"@${cue.start} '
            'REVERSED by "${wrap.marker}"@${wrap.start}',
      ));
    }
  }

  // ---- D2: bank-profile type rule ---------------------------------------
  // The rule must be one the profile declares for a type in the predeclared
  // polarity map. A rule for `transfer` matches nothing here on purpose.
  if (bank != null) {
    final lower = sms.toLowerCase();
    for (final entry in bank.typeRules.entries) {
      final polarity = kDeterministicTypePolarity[entry.key];
      if (polarity == null) continue; // direction-ambiguous type: no vote
      for (final rule in entry.value) {
        final needle = rule.toLowerCase();
        if (needle.isEmpty) continue;
        final at = lower.indexOf(needle);
        if (at < 0) continue;
        _ReversalScope? wrap;
        for (final s in scopes) {
          if (s.covers(at)) {
            wrap = s;
            break;
          }
        }
        out.add(DirectionCorroborator(
          source: CorroborationSource.d2BankProfile,
          polarity: wrap == null ? polarity : invert(polarity),
          provenance: 'D2 bank:${bank.bankKey} '
              'typeRule:${entry.key.name}("$rule")'
              '${wrap == null ? '' : ' REVERSED by "${wrap.marker}"'}',
        ));
        break; // one vote per type rule set; provenance names the rule
      }
    }
  }

  // ---- D3: catalog rule --------------------------------------------------
  if (catalogRule != null) {
    final type = catalogRuleType(catalogRule);
    final polarity = kDeterministicTypePolarity[type];
    // A catalog rule matches the WHOLE message, so it has no span and its
    // relationship to a reversal clause cannot be established. Per the rev-7
    // contract its vote is SUPPRESSED rather than guessed: it may not
    // corroborate the unwrapped polarity, and inverting it would be inventing
    // a scope that was never proven.
    if (reversalPresent) {
      // no D3 vote
    } else if (polarity != null) {
      final literal = catalogRule.extractedFields['type'];
      final explicit = literal is String && literal.trim().isNotEmpty;
      out.add(DirectionCorroborator(
        source: CorroborationSource.d3CatalogRule,
        polarity: polarity,
        provenance: 'D3 catalog:${catalogRule.id} '
            '${explicit ? 'type=$literal' : 'transaction_type=${catalogRule.transactionType}'}'
            ' -> ${type.name}',
      ));
    }
  }

  return out;
}

/// How the corroborators resolved, independent of what the model proposed.
enum DirectionOutcome {
  /// Authoritative sources agree on exactly one polarity.
  corroborated,

  /// Nothing authoritative said anything.
  ambiguous,

  /// Authoritative sources disagree with each other.
  conflict,
}

/// The deterministic resolution. [polarity] is set only when [outcome] is
/// [DirectionOutcome.corroborated].
class DirectionResolution {
  const DirectionResolution(this.outcome, this.polarity, this.corroborators);

  final DirectionOutcome outcome;
  final DirectionCuePolarity? polarity;
  final List<DirectionCorroborator> corroborators;

  /// The provenance of every source that voted, for the review reason.
  List<String> get provenance =>
      corroborators.map((c) => c.provenance).toList(growable: false);
}

/// Resolve the deterministic corroborators among themselves.
///
/// Disagreement between authoritative sources is NEVER broken by majority,
/// priority or recency. Two deterministic layers contradicting each other is a
/// statement that the message is genuinely unclear, and the only safe reading
/// of an unclear money direction is to stop.
DirectionResolution resolveDirection(List<DirectionCorroborator> corroborators) {
  if (corroborators.isEmpty) {
    return DirectionResolution(DirectionOutcome.ambiguous, null, corroborators);
  }
  final polarities = corroborators.map((c) => c.polarity).toSet();
  if (polarities.length > 1) {
    return DirectionResolution(DirectionOutcome.conflict, null, corroborators);
  }
  return DirectionResolution(
      DirectionOutcome.corroborated, polarities.first, corroborators);
}
