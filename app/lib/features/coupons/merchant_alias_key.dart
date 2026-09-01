import 'merchant_alias_key_tables.dart';

/// FROZEN v1 merchant lookup keys — the Dart half of a two-implementation
/// contract. The other half is `merchant_alias_key_v1()` /
/// `merchant_domain_key_v1()` in PostgreSQL, which backs the stored generated
/// column and the partial unique index on `catalog_merchant_aliases`.
///
/// Specification: `docs/coupons/MERCHANT_ALIAS_KEY_V1.md`.
/// Fold tables:   `docs/coupons/merchant_alias_key_v1.tables.json` (generated
///                into both languages; a test asserts the artifacts match).
///
/// The client must resolve merchants OFFLINE, so it cannot ask the server for a
/// key; the server needs the key inside an index expression, so it cannot call
/// Dart. Duplication is forced. Drift is controlled by generating both tables
/// from one source and by running a shared fixture corpus through BOTH — the
/// Dart test here and a contract test against a real migrated database.
///
/// ## Never edit this to change behaviour
///
/// These functions are frozen. A behavioural change is a new version: a `_v2`
/// function, a transactional re-key of every stored alias, a rebuild of the
/// partial unique index, and client gating on `key_version`. Editing in place
/// leaves every stored key and every device cache silently wrong, with no error
/// anywhere — PostgreSQL does not recompute a stored generated column when the
/// function behind it is replaced.
class MerchantAliasKey {
  const MerchantAliasKey._();

  /// The NAME key. See the spec for the ordered steps; the short version is:
  /// ASCII case fold, drop diacritics/tatweel, fold Arabic letter variants,
  /// fold Arabic-Indic digits to ASCII and KEEP them, map everything outside
  /// the keep set to one space, collapse, trim.
  ///
  /// Returns `''` when nothing survives. **An empty key is not a key** — callers
  /// must abstain rather than look it up, or every input that folds away would
  /// share one bucket.
  static String name(String input) {
    final out = StringBuffer();
    var pendingSpace = false;
    var wroteAny = false;

    // Iterate Unicode scalar values. `split('')` would iterate UTF-16 code
    // units and shear surrogate pairs, which PostgreSQL — working in code
    // points — would not, and the two implementations would silently disagree.
    for (final rune in input.runes) {
      // step 3 — diacritics and tatweel vanish entirely (not to a space, so
      // `كارفـــور` stays one word rather than becoming three).
      if (kAliasKeyDiacriticsV1.contains(rune)) continue;

      // step 2 — ASCII case fold only. Deliberately not `toLowerCase()`.
      var cp = kAliasKeyCaseFoldsV1[rune] ?? rune;
      // step 4 — Arabic/Persian letter folds.
      cp = kAliasKeyLetterFoldsV1[cp] ?? cp;
      // step 5 — Arabic-Indic digits to ASCII; digits are then KEPT.
      cp = kAliasKeyDigitFoldsV1[cp] ?? cp;

      if (kAliasKeyKeepV1.contains(cp)) {
        // steps 7 + 8 folded into the walk: a pending separator is only
        // emitted once, and only between two kept characters, so leading and
        // trailing runs never reach the output.
        if (pendingSpace && wroteAny) out.writeCharCode(0x20);
        pendingSpace = false;
        out.writeCharCode(cp);
        wroteAny = true;
      } else {
        // step 6 — everything else is a separator.
        pendingSpace = true;
      }
    }
    return out.toString();
  }

  /// The DOMAIN key — a SEPARATE contract, because digits, dots and hyphens are
  /// semantically load-bearing in a hostname. `7eleven.com` run through [name]
  /// would become a different company.
  ///
  /// Takes an already-extracted **host**, not a URL: use [hostFrom] first. URL
  /// parsing and IDNA stay on the client because PostgreSQL ships neither, and
  /// an IDNA implementation that differs by one code point is exactly the drift
  /// this design exists to prevent.
  ///
  /// Returns `''` for anything that is not a plain ASCII hostname — including a
  /// Unicode host, which is rejected rather than converted.
  static String domain(String host) {
    var s = host.trim();
    final buf = StringBuffer();
    for (final rune in s.runes) {
      buf.writeCharCode(kAliasKeyCaseFoldsV1[rune] ?? rune);
    }
    s = buf.toString();
    if (s.startsWith('www.')) s = s.substring(4);
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return _hostShape.hasMatch(s) ? s : '';
  }

  /// Extracts a host from a URL or a bare host. Returns `''` when there is
  /// nothing host-shaped, so the caller abstains rather than keying garbage.
  static String hostFrom(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    final withScheme =
        trimmed.contains('://') ? trimmed : 'https://$trimmed';
    try {
      final host = Uri.parse(withScheme).host;
      return host;
    } on FormatException {
      return '';
    }
  }

  static final RegExp _hostShape =
      RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$');
}
