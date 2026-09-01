/// Deterministic cue-role assignment for the proof checker.
///
/// WHY THIS FILE EXISTS
/// The proof checker resolves the amount by evidence ID, which makes
/// fabrication impossible: the model cannot contribute a digit. It does NOT
/// make *selection* safe. Every number in the message is a legitimate evidence
/// node, so a model that points at the balance, the card suffix or the VAT line
/// produces a proposal that is perfectly well-formed and completely wrong.
///
///     Purchase SAR 40.00. Available balance SAR 9,120.75
///
/// Both numbers are complete tokens of the message. Only one of them is the
/// transaction. Without this layer the checker has no basis to prefer either,
/// and `9,120.75` auto-commits.
///
/// This is a port of the research layer (`cue_roles_v2.py`) that the frozen
/// benchmark measures. It exists so the phone runs the architecture the
/// benchmark scores — a safety gate that is only present in the harness proves
/// nothing about the shipped app.
///
/// HOW ROLES ARE ASSIGNED
///  1. NEAREST-CUE GOVERNANCE — a cue governs exactly ONE number: the nearest,
///     by character distance.
///  2. CUE CONSUMPTION — having governed that number, a cue cannot reach past
///     it to a second one.
///  3. NO CROSS-TOKEN CONTAMINATION — a cue may not reach a number if another
///     numeric token lies between them.
///
/// DIRECTIONALITY: a cue governs the nearest number AFTER it. `balance` alone
/// may also look backwards, for Arabic layouts like `840.230 د.ك المتاح`, and
/// only when no eligible number follows. On equal distance the forward number
/// wins: bank formats overwhelmingly write the cue before its number.
///
/// This file contains no bank name, no merchant string and no message-specific
/// constant. It is defined purely in terms of character distance and
/// intervening-token structure.
library;

import 'amount_candidates.dart' show kCurrencyAdjacency;
import 'evidence.dart';

/// Roles that make a number INELIGIBLE to carry financial authority.
///
/// `total` is deliberately absent. In `Total charged AED 47.25` the total IS
/// the transaction amount; blocking it was the defect that failed the first
/// Phase-4 seal, and it failed in the worst possible direction — the correct
/// amount was blocked while a line-item stayed eligible and committed.
///
/// `vat` blocks for the same reason `fee` does: a tax line is a component, not
/// the transaction. Both are waived when the transaction genuinely IS a fee.
const Set<String> kBlockingCueRoles = {
  'balance',
  'fee',
  'vat',
  'accountRef',
};

/// A cue further away than this governs nothing. Measured across the gap
/// between cue and token, not from an arbitrary window origin.
const int kMaxCueDistance = 24;

/// Bare digit runs at least this long are references by structure alone.
const int _kMinBareDigitsForRef = 6;

const Map<String, List<String>> _cues = {
  'balance': [
    'الرصيد', 'رصيد', 'المتاح', 'المتبقي',
    'balance', 'bal.', 'bal ', 'avl', 'available', 'avail', 'avlbl',
    'remaining',
  ],
  // Explicit fee/tax NOUNS only. The VERB forms `charged`/`charging` are
  // deliberately absent — `your card was charged SAR 320.00` is an ordinary
  // purchase. The bare noun `charge` IS present; the two are separated by
  // word-boundary matching, not by a longer word list, so `charge KWD 0.500`
  // is a fee while `charged KWD 0.500` is not.
  'fee': [
    'رسوم', 'عمولة', 'مصاريف',
    'fee', 'fees', 'commission', 'charge', 'charges',
  ],
  'vat': ['ضريبة', 'الضريبة', 'vat', 'tax'],
  // Descriptive only — see kBlockingCueRoles.
  'total': ['الإجمالي', 'اجمالي', 'total'],
  // An identifier cue may only claim a number that is STRUCTURALLY an
  // identifier. A reference sitting beside an amount in an unrelated clause
  // must not contaminate it: in `REF 9928374 purchase SAR 210.00` the
  // reference owns 9928374, not 210.00.
  'accountRef': [
    'بطاقة', 'بطاقتكم', 'المنتهي', 'حساب', 'الحساب', 'رقم', 'مرجع',
    'acct', 'a/c', 'account', 'acc ', 'card', 'ending', 'ref', 'reference',
    'trn', 'txn id', 'no.',
  ],
};

final RegExp _latinCue = RegExp(r'^[a-z /.]+$');
final RegExp _latinWordChar = RegExp('[a-z0-9]');
final RegExp _maskedPrefix = RegExp(r'[xX*#٭]{2,}\s*$');
final RegExp _decimalSeparator = RegExp('[.,٫٬]');
final RegExp _nonDigit = RegExp(r'\D');

/// True when `[i, j)` is a whole Latin word rather than a fragment of one.
///
/// This is what separates the fee NOUN `charge` from the transaction VERB
/// `charged`: morphologically they are different words, and English marks the
/// difference with a suffix. Substring matching cannot see that.
///
/// Latin cues only. Arabic takes clitic prefixes directly onto the stem —
/// `ورسوم` is "and fees", `بالرصيد` is "in the balance" — so demanding a
/// boundary there would silently stop matching real cues.
bool _boundaryOk(String low, int i, int j) {
  final before = i > 0 ? low[i - 1] : ' ';
  final after = j < low.length ? low[j] : ' ';
  return !_latinWordChar.hasMatch(before) && !_latinWordChar.hasMatch(after);
}

/// A monetary amount carries a decimal separator or thousands grouping; a card
/// suffix, reference or account number is a bare digit run. Requiring the shape
/// is what stops `REF 9928374 purchase SAR 210.00` from marking 210.00, which
/// proximity alone cannot distinguish.
bool _isIdentifierShaped(String raw) => !_decimalSeparator.hasMatch(raw);

class _Cue {
  const _Cue(this.start, this.end, this.role);
  final int start;
  final int end;
  final String role;
}

List<_Cue> _cuePositions(String low) {
  final out = <_Cue>[];
  _cues.forEach((role, words) {
    for (final w in words) {
      final needle = w.toLowerCase();
      final latin = _latinCue.hasMatch(needle);
      var from = 0;
      while (true) {
        final i = low.indexOf(needle, from);
        if (i < 0) break;
        if (!latin || _boundaryOk(low, i, i + needle.length)) {
          out.add(_Cue(i, i + needle.length, role));
        }
        from = i + 1;
      }
    }
  });
  return out;
}

/// Roles for each NUMBER node in [evidence], keyed by evidence id.
///
/// Spans are UTF-16 code-unit offsets into [sms], the same indexing the
/// evidence layer produces, so a node is looked up by its own span without any
/// re-tokenisation.
Map<String, Set<String>> cueRoles(EvidenceSet evidence) {
  final sms = evidence.source;
  // A number sitting against a currency token is MONEY, whatever its shape.
  // Without this, `مبلغ:300 SAR` loses its amount entirely: `300` carries no
  // decimal separator, so the identifier-shape test called it identifier-like,
  // and a `بطاقة` cue earlier in the message claimed it as a card reference.
  // The message names the currency right against the number — that outranks a
  // shape heuristic, and an identifier is never quoted in a currency.
  final moneyBacked = _currencyBackedIds(evidence);
  final numbers = evidence.ofClass(EvidenceClass.number).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  if (numbers.isEmpty) return const {};

  final low = sms.toLowerCase();
  final roles = <String, Set<String>>{
    for (final n in numbers) n.id: <String>{},
  };

  // ---- structural roles: no cue required --------------------------------
  for (final n in numbers) {
    final head = sms.substring(n.start < 6 ? 0 : n.start - 6, n.start);
    if (_maskedPrefix.hasMatch(head)) {
      roles[n.id]!.add('accountRef');
    }
    final digitsOnly = n.text.replaceAll(_nonDigit, '');
    if (!_decimalSeparator.hasMatch(n.text) &&
        digitsOnly.length >= _kMinBareDigitsForRef) {
      roles[n.id]!.add('accountRef');
    }
  }

  // ---- nearest-cue governance -------------------------------------------
  for (final cue in _cuePositions(low)) {
    Evidence? after;
    for (final n in numbers) {
      if (n.start >= cue.end) {
        after = n;
        break;
      }
    }
    Evidence? before;
    for (final n in numbers.reversed) {
      if (n.end <= cue.start) {
        before = n;
        break;
      }
    }

    Evidence? target;
    if (after != null) {
      // CROSS-TOKEN GUARD: nothing numeric may sit between cue and token.
      final blocked = numbers
          .any((t) => t.start >= cue.end && t.start < after!.start);
      if (!blocked && after.start - cue.end <= kMaxCueDistance) {
        target = after;
      }
    }
    if (target == null && before != null && cue.role == 'balance') {
      final blocked =
          numbers.any((t) => t.end <= cue.start && t.end > before!.end);
      if (!blocked && cue.start - before.end <= kMaxCueDistance) {
        target = before;
      }
    }
    if (target == null) continue;

    // An identifier cue may only claim an identifier-SHAPED number. Without
    // this, `your card was charged SAR 320.00` lets the card cue claim the
    // amount, because the amount is the nearest number to it.
    if (cue.role == 'accountRef' &&
        (!_isIdentifierShaped(target.text) || moneyBacked.contains(target.id))) {
      continue;
    }
    roles[target.id]!.add(cue.role);
  }

  return roles;
}

/// Ids of NUMBER nodes that a currency token directly backs.
///
/// Nearest-governance, matching `amount_candidates.dart`: a currency belongs to
/// the one number closest to it, so a currency cannot vouch for every digit on
/// its line.
Set<String> _currencyBackedIds(EvidenceSet evidence) {
  final numbers = evidence.ofClass(EvidenceClass.number).toList();
  final backed = <String>{};
  for (final c in evidence.ofClass(EvidenceClass.currency)) {
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
    if (nearest != null) backed.add(nearest.id);
  }
  return backed;
}
