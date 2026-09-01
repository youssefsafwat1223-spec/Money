/// Deterministic multi-amount ambiguity — the fail-closed selection gate.
///
/// ## The failure this exists to stop
///
/// In
///
///     POS AED 45.00 / VAT AED 2.25 / Total charged AED 47.25
///
/// the model selected `45.00`. That token is real, complete, correctly spanned
/// and carries no blocking cue role — every guarantee the proof architecture
/// offers was satisfied, and the answer was still wrong. Resolving the amount
/// by evidence ID prevents the model from INVENTING a number. It does nothing
/// to stop it CHOOSING the wrong real one.
///
/// ## Why there is no ranking rule here
///
/// The obvious repairs — largest wins, last wins, the total wins — are all
/// heuristics about document layout, not properties of the message. Each is
/// wrong on a message someone will eventually receive: the largest number is
/// often the balance, the last is often a reference, and "total" marks an
/// instalment's outstanding balance as readily as it marks the amount charged.
/// A heuristic that is usually right is a heuristic that silently books the
/// wrong amount for the minority, which is the exact failure mode this
/// architecture exists to make impossible.
///
/// So: when more than one candidate survives deterministic filtering, the
/// message goes to REVIEW. The model may SELECT evidence. It may not RESOLVE
/// financial ambiguity. Ambiguity is a property of the message, and the honest
/// response to it is a question, not a guess.
///
/// The coverage this costs is real and is the point.
library;

import '../parser/bank_profile.dart';
import 'cue_roles.dart';
import 'evidence.dart';

/// How close a currency token must sit to a number for that number to read as
/// monetary. Deliberately tight: it is meant to catch `SAR 24` and `24 ر.س`,
/// not to associate a currency with every digit on the line.
const int kCurrencyAdjacency = 10;

/// Numbers that could plausibly be the transaction amount.
///
/// A NUMBER node is a candidate when all of these hold:
///   · it has a canonical value (an ambiguous token can never be an amount);
///   · it carries no BLOCKING cue role — not a balance, fee, tax or identifier;
///   · it is MONETARY by structure, meaning it either carries a decimal
///     separator or sits within [kCurrencyAdjacency] of a currency token.
///
/// The monetary test is what keeps dates and card digits out. `13/6/26 16:03`
/// contributes bare integers with no decimal part and no adjacent currency, so
/// none of them compete with the amount. Without it every timestamp in every
/// message would manufacture ambiguity and nothing would ever commit.
List<Evidence> amountCandidates(EvidenceSet evidence, {BankProfile? bank}) {
  final roles = cueRoles(evidence);
  final totalDue = totalDueExclusions(evidence, bank);
  final currencies = evidence.ofClass(EvidenceClass.currency).toList();

  // A currency governs the NEAREST number, exactly as a cue governs the
  // nearest number in `cue_roles.dart`. Flat proximity is not enough: in
  //
  //     شراء PoS عبر:6826;مدى بـSAR 24
  //
  // the terminal id 6826 sits within a few characters of `SAR`, but the SAR
  // belongs to 24. Without nearest-governance the terminal id becomes a rival
  // candidate and a perfectly clear message goes to review.
  final numbers = evidence.ofClass(EvidenceClass.number).toList();
  final currencyBacked = <String>{};
  for (final c in currencies) {
    Evidence? nearest;
    var best = 1 << 30;
    for (final n in numbers) {
      final gap = c.start >= n.end ? c.start - n.end : n.start - c.end;
      if (gap < 0 || gap > kCurrencyAdjacency) continue;
      if (gap < best) {
        best = gap;
        nearest = n;
      }
    }
    if (nearest != null) currencyBacked.add(nearest.id);
  }

  return evidence
      .ofClass(EvidenceClass.number)
      .where((n) => n.canonical != null)
      .where((n) =>
          (roles[n.id] ?? const <String>{}).intersection(kBlockingCueRoles).isEmpty)
      .where((n) => (n.decimals ?? 0) > 0 || currencyBacked.contains(n.id))
      .where((n) => !totalDue.containsKey(n.id))
      .toList(growable: false);
}

/// Numbers a bank profile's OWN `totalDueRules` identify as an outstanding
/// balance rather than this transaction, keyed by evidence id, valued by the
/// rule that established it.
///
/// This is deliberately NOT a ranking heuristic. A monetary token is excluded
/// only when a deterministic production rule that already ships in the bank
/// profile names it — today exactly one profile declares such a rule
/// (`bsf: المبلغ الإجمالي المستحق`), so exactly the messages that rule covers
/// are affected and no others.
///
/// The generic words `total`, `due`, `الإجمالي` and `المستحق` do NOT trigger
/// this on their own, and neither does position in the message. If no profile
/// rule applies, a second monetary amount stays a candidate and the message
/// goes to REVIEW(amountAmbiguous) — ambiguity is preserved, not guessed away.
Map<String, String> totalDueExclusions(EvidenceSet evidence, BankProfile? bank) {
  if (bank == null || bank.totalDueRules.isEmpty) return const {};
  final lower = evidence.source.toLowerCase();
  final numbers = evidence.ofClass(EvidenceClass.number).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final out = <String, String>{};
  for (final rule in bank.totalDueRules) {
    final needle = rule.toLowerCase().trim();
    if (needle.isEmpty) continue;
    var from = 0;
    while (true) {
      final i = lower.indexOf(needle, from);
      if (i < 0) break;
      final end = i + needle.length;
      from = i + 1;
      // Nearest number AFTER the rule, with nothing numeric in between —
      // the same governance the cue layer uses, so a rule cannot reach past
      // one number to claim another.
      for (final n in numbers) {
        if (n.start < end) continue;
        if (n.start - end <= kMaxCueDistance) {
          out[n.id] = 'totalDue bank:${bank.bankKey} rule:"$rule"';
        }
        break;
      }
    }
  }
  return out;
}
