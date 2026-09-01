import 'merchant_alias_key.dart';

/// What a shared piece of text is, and therefore where it may go.
enum SharedContentKind {
  /// A bank message. Goes to the financial capture queue and the parser.
  capture,

  /// A merchant link. Goes to the OFFER-INTENT path and must never reach the
  /// capture queue or the SMS parser.
  offerUrl,

  /// Neither — empty, or something we cannot classify. Dropped.
  ignored,
}

class SharedContent {
  const SharedContent(this.kind, {this.sanitizedUrl, this.host, this.text});

  final SharedContentKind kind;

  /// Scheme + host + path only. Query and fragment are REMOVED — see below.
  final String? sanitizedUrl;
  final String? host;

  /// The original text, for the capture path only.
  final String? text;
}

/// Decides where shared content goes, and strips what it must not carry.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// A MERCHANT URL MUST NEVER ENTER THE FINANCIAL CAPTURE QUEUE.
/// ═══════════════════════════════════════════════════════════════════════════
///
/// Today every shared `text/plain` goes to `DurableCaptureQueue` and then to the
/// SMS parser. That was correct when the only thing anyone shared was a bank
/// message. Once a user can share a shop link, it stops being correct in three
/// separate ways:
///
///   * the parser would try to read a product page as a transaction, and a URL
///     containing digits and a currency word is exactly the shape it looks for;
///   * a shopping URL would be persisted in the financial capture store, which
///     is encrypted for bank messages and syncs under financial consent;
///   * the user would have shared a link and received a transaction.
///
/// So classification happens at the NATIVE boundary, before anything is
/// enqueued, and the two paths never touch.
///
/// ## Why the query string is destroyed
///
/// A shared shopping URL routinely carries: a session id, a cart id, the user's
/// own referral code, search terms, and analytics parameters that identify the
/// person who shared it. None of it is needed to know which merchant this is —
/// the host alone answers that — and all of it would be persisted on the device
/// and potentially resolved against the catalog.
///
/// Keeping the path but dropping query and fragment is the smallest thing that
/// still identifies a merchant. We do not need to know WHAT someone was
/// looking at.
class SharedContentRouter {
  const SharedContentRouter._();

  /// Anything longer than this is prose that happens to contain a link, not a
  /// shared link. A user sharing a bank SMS that quotes a URL must still reach
  /// the capture path.
  static const int _maxUrlShareLength = 512;

  static final RegExp _urlish = RegExp(r'^\s*(?:https?://)?[^\s]+\.[^\s]{2,}\s*$');
  static final RegExp _hasScheme = RegExp(r'^\s*https?://', caseSensitive: false);

  /// ANY scheme, not just http(s).
  ///
  /// Needed before the http-prepending step. `mailto:a@b.com` with `https://`
  /// glued on parses as userInfo `mailto:a` and host `b.com` — so a shared
  /// email address would have been classified as an offer link to the
  /// recipient's domain. Found by the test that expected mailto to reach the
  /// capture path.
  static final RegExp _anyScheme =
      RegExp(r'^\s*[a-z][a-z0-9+.\-]*:', caseSensitive: false);

  /// Classify shared text.
  ///
  /// The rule is deliberately CONSERVATIVE toward capture: only text that is
  /// essentially nothing but a URL is treated as an offer link. A bank message
  /// that happens to contain a link is still a bank message, and misrouting one
  /// would silently lose a transaction the user expected to be recorded — a
  /// worse failure than showing them a merchant page they did not ask for.
  static SharedContent classify(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return const SharedContent(SharedContentKind.ignored);

    // Multi-line or long content is prose. A shared URL is one token.
    if (text.contains('\n') || text.length > _maxUrlShareLength || !_urlish.hasMatch(text)) {
      return SharedContent(SharedContentKind.capture, text: text);
    }

    // A non-http(s) scheme is not a merchant link, and it must be rejected
    // BEFORE any prepending — see _anyScheme.
    if (_anyScheme.hasMatch(text) && !_hasScheme.hasMatch(text)) {
      return SharedContent(SharedContentKind.capture, text: text);
    }

    final withScheme = _hasScheme.hasMatch(text) ? text : 'https://$text';
    final Uri uri;
    try {
      uri = Uri.parse(withScheme);
    } on FormatException {
      return SharedContent(SharedContentKind.capture, text: text);
    }

    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return SharedContent(SharedContentKind.capture, text: text);
    }
    // Credentials in a URL are not something a merchant share carries, and
    // storing one would persist someone's password.
    if (uri.userInfo.isNotEmpty) {
      return SharedContent(SharedContentKind.capture, text: text);
    }

    final host = MerchantAliasKey.domain(uri.host);
    if (host.isEmpty) {
      // Not a resolvable hostname. Treat as capture rather than dropping it —
      // the user shared SOMETHING, and the capture path can at least tell them
      // it was not a transaction.
      return SharedContent(SharedContentKind.capture, text: text);
    }

    // Rebuilt from parts. Never a substring of the original, so nothing from the
    // query or fragment can survive by accident.
    final sanitized = Uri(
      scheme: 'https',
      host: uri.host.toLowerCase(),
      path: uri.path.isEmpty ? '/' : uri.path,
    ).toString();

    return SharedContent(
      SharedContentKind.offerUrl,
      sanitizedUrl: sanitized,
      host: host,
    );
  }

  /// The sanitizer on its own, for the native side to mirror.
  ///
  /// Returns '' when the value is not a usable http(s) URL, which the caller
  /// must treat as "do not store this as an offer intent".
  static String sanitizeUrl(String raw) {
    final classified = classify(raw);
    return classified.kind == SharedContentKind.offerUrl
        ? classified.sanitizedUrl!
        : '';
  }
}
