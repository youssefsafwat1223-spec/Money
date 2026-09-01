import '../../data/catalog/catalog_daos.dart';
import 'merchant_alias_key.dart';

/// How a merchant string was resolved — or why it was not.
///
/// `abstained` is a first-class outcome, not a failure. For categorization a
/// wrong guess costs a wrong chip the user can fix. Here the output feeds
/// "offers for places you shop", so a wrong guess tells someone they shop
/// somewhere they have never been, derived from reading their bank messages.
/// Abstaining is always the cheaper error.
enum MerchantMatchOutcome {
  /// Exactly one reviewed alias matched, in a scope we are entitled to use.
  resolved,

  /// Nothing matched. The catalog simply does not cover this string yet — an
  /// alias-coverage problem, solved by adding data, never by loosening matching.
  noMatch,

  /// Something matched, but not unambiguously enough to act on: several
  /// merchants claim the same key in scopes we cannot choose between, or the
  /// key folded away to nothing.
  ambiguous,
}

/// Which stage produced the match. Diagnostic only — it never affects the
/// result — but it is what makes a bad alias findable in the field.
enum MerchantMatchStage { exact, stripped, domain }

class MerchantMatch {
  const MerchantMatch._(this.outcome, {this.merchantId, this.stage, this.matchedKey});

  const MerchantMatch.resolved({
    required String merchantId,
    required MerchantMatchStage stage,
    required String matchedKey,
  }) : this._(MerchantMatchOutcome.resolved,
            merchantId: merchantId, stage: stage, matchedKey: matchedKey);

  static const noMatch = MerchantMatch._(MerchantMatchOutcome.noMatch);
  static const ambiguous = MerchantMatch._(MerchantMatchOutcome.ambiguous);

  final MerchantMatchOutcome outcome;
  final String? merchantId;
  final MerchantMatchStage? stage;
  final String? matchedKey;

  bool get isResolved => outcome == MerchantMatchOutcome.resolved;
}

/// Evidence about where a transaction happened.
///
/// Deliberately NOT the device locale, NOT the device location, NOT the card
/// issuer's country and NOT the transaction currency. A KSA-issued card used in
/// Egypt yields "SA" from every one of those, and would then select an
/// SA-scoped alias for an Egyptian merchant — a wrong merchant, silently.
///
/// Only the merchant's or acquirer's own location counts. Phase 1's parser
/// produces none, so [merchantCountry] is null in practice and the resolver runs
/// global-only. The path is implemented and tested so that it is correct when
/// such evidence exists; shipping it live off issuer country would be exactly
/// the bug this class exists to prevent.
class MerchantLocationEvidence {
  const MerchantLocationEvidence({this.merchantCountry});

  /// ISO-3166 alpha-2, uppercase, or null when unknown.
  final String? merchantCountry;

  static const unknown = MerchantLocationEvidence();
}

/// `MerchantLookupPipeline.v1` — the query-side half of the merchant contract.
///
/// The frozen key functions (`merchant_alias_key_v1`) hold no lexicon by design:
/// a bank-boilerplate list inside the key would make every new acquirer prefix a
/// full key-version migration — new function, transactional re-key of every
/// stored alias, index rebuild, client gating — for what is really a content
/// change. Here, outside the key, the same change is a lexicon update in the
/// next release that can only ever affect the string being looked up, never a
/// stored identity.
///
/// The database rejects any alias containing something this pipeline would
/// strip, so a stored alias and a stripped query can never disagree about what a
/// merchant is called. See `docs/coupons/MERCHANT_ALIAS_KEY_V1.md`.
class MerchantLookupPipeline {
  const MerchantLookupPipeline(this._aliases);

  final RemoteMerchantAliasesDao _aliases;

  /// Resolve a parsed merchant string to a canonical merchant.
  ///
  /// [rawMerchant] is the string the parser produced. It has ALREADY had
  /// `PaymentAggregators.resolveMerchant` applied upstream in
  /// `add_transaction_usecase.dart`; this pipeline must not apply it again,
  /// because that function's separator class includes plain whitespace and
  /// re-running it on an arbitrary string would truncate a merchant whose name
  /// legitimately begins with a gateway token.
  Future<MerchantMatch> resolve(
    String rawMerchant, {
    String? merchantUrl,
    MerchantLocationEvidence evidence = MerchantLocationEvidence.unknown,
  }) async {
    // Stage 1 — the unstripped key FIRST.
    //
    // Ordering matters for safety, not just for speed. If the catalog holds
    // `PAYMENT SOLUTIONS` for one merchant and `SOLUTIONS` for another, trying
    // the full string first means the exact catalogued intent always wins; a
    // strip-first pipeline with an over-eager lexicon would hand the user the
    // other merchant.
    final exact = MerchantAliasKey.name(rawMerchant);
    if (exact.isNotEmpty) {
      final match = await _lookup(exact, 'name', MerchantMatchStage.exact, evidence);
      if (match != null) return match;
    }

    // Stage 2 — strip what a bank wrapped around the name, then try again.
    final stripped = MerchantAliasKey.name(stripLookupNoise(rawMerchant));
    if (stripped.isNotEmpty && stripped != exact) {
      final match =
          await _lookup(stripped, 'name', MerchantMatchStage.stripped, evidence);
      if (match != null) return match;
    }

    // Stage 3 — a domain, when the parser gave us one. A separate key contract:
    // digits, dots and hyphens are load-bearing in a hostname, so `7eleven.com`
    // must never be folded the way a name is.
    if (merchantUrl != null && merchantUrl.trim().isNotEmpty) {
      final host = MerchantAliasKey.domain(MerchantAliasKey.hostFrom(merchantUrl));
      if (host.isNotEmpty) {
        final match =
            await _lookup(host, 'domain', MerchantMatchStage.domain, evidence);
        if (match != null) return match;
      }
    }

    // An empty key at every stage means the string folded away entirely —
    // punctuation, an emoji, diacritics alone. That is not "no match", it is
    // "nothing to match with", and it must never be looked up: every such input
    // produces the same empty key and would share one bucket.
    if (exact.isEmpty && stripped.isEmpty) return MerchantMatch.ambiguous;
    return MerchantMatch.noMatch;
  }

  /// Returns null when this key matched nothing at all, so the caller falls
  /// through to the next stage. Returns [MerchantMatch.ambiguous] when it
  /// matched something we are not entitled to choose between — that DOES stop
  /// the pipeline, because a later stage finding a different merchant for a
  /// looser form of the same string would be the wrong answer, not a better one.
  Future<MerchantMatch?> _lookup(
    String key,
    String kind,
    MerchantMatchStage stage,
    MerchantLocationEvidence evidence,
  ) async {
    final candidates = await _aliases.candidatesFor(key, kind);
    if (candidates.isEmpty) return null;

    final country = evidence.merchantCountry?.toUpperCase();
    final scoped = country == null
        ? const <RemoteMerchantAlias>[]
        : candidates.where((a) => a.countryCode?.toUpperCase() == country).toList();
    final global = candidates.where((a) => a.countryCode == null).toList();

    // A country-scoped alias outranks a global one — but only because we have
    // evidence about where the merchant is, never because of where the phone is.
    final tier = scoped.isNotEmpty ? scoped : global;

    // Rows scoped to some OTHER country are not evidence about this
    // transaction, so they are simply not candidates.
    if (tier.isEmpty) return null;

    final merchants = tier.map((a) => a.merchantId).toSet();
    if (merchants.length > 1) {
      // Two merchants hold the same reviewed key in the same scope. The server's
      // partial unique index makes this impossible to create deliberately, so
      // reaching it means the cache is mid-update or an admin changed an
      // assignment. Either way, guessing would attribute someone's spending to a
      // business at random.
      return MerchantMatch.ambiguous;
    }

    return MerchantMatch.resolved(
      merchantId: merchants.first,
      stage: stage,
      matchedKey: key,
    );
  }

  // ── the lexicon ──────────────────────────────────────────────────────────
  //
  // Anchored MULTI-WORD wrappers only. Bare `pos`, `purchase`, `payment`,
  // `شراء` and `دفع` are deliberately absent even though text_normalizer.dart
  // strips them: they are plausible beginnings of real business names, and
  // removing them turns "PAYMENT SOLUTIONS" into a different merchant called
  // "Solutions". That is right for a fuzzy classifier and wrong here.
  static final RegExp _leadingWrapper = RegExp(
    r'^(?:'
    r'pos purchase|card purchase|purchase at|payment to|point of sale'
    r'|شراء من|مشتريات من|عمليه شراء|دفع الى'
    r') ',
  );

  // Marker-introduced identifiers. The digits are REQUIRED — `+`, not `*`.
  // text_normalizer.dart:36 uses `*`, so it strips a bare trailing marker and
  // turns "CAFE TRACE" into "CAFE", inventing a match against a different shop.
  static final RegExp _markerIdentifier = RegExp(
    r'(^| )(?:branch|term|terminal|ref|txn|trace|auth|فرع|ترمينال|مرجع) [0-9]+(?= |$)',
  );

  /// Removes only what the database also refuses to store, so the catalog and
  /// the query can never disagree about what counts as noise.
  ///
  /// Operates on the CANONICALISED form: a raw-text lexicon would miss
  /// `POS-PURCHASE CARREFOUR`, which becomes `pos purchase carrefour` only after
  /// the key's separator step.
  static String stripLookupNoise(String raw) {
    var s = MerchantAliasKey.name(raw);
    // Repeat: a bank can wrap twice ("POS PURCHASE PAYMENT TO X"), and one pass
    // would leave the inner wrapper attached and produce a key nobody catalogs.
    for (var i = 0; i < 3; i++) {
      final next = s.replaceFirst(_leadingWrapper, '');
      if (next == s) break;
      s = next;
    }
    s = s.replaceAll(_markerIdentifier, '');
    return s.replaceAll(RegExp(' +'), ' ').trim();
  }
}
