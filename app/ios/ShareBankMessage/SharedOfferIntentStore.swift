import Foundation

/// COUPONS Phase 5 — shared merchant links, staged for the Flutter host.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// DELIBERATELY SEPARATE FROM SharedCaptureStore.
/// ═══════════════════════════════════════════════════════════════════════════
///
/// A shared shop link and a shared bank message are different kinds of thing
/// and must not share a store. Putting a URL into the capture queue would mean
/// the SMS parser reading a product page as a transaction — URLs are full of
/// digits and currency words, exactly the shape it looks for — and a shopping
/// URL persisted in the store built for bank messages, which is encrypted for
/// that purpose and drains under financial consent.
///
/// Two stores make that impossible rather than merely unlikely.
///
/// ## What is stored, and what is destroyed
///
/// Scheme, host and path. The query and fragment are removed before anything is
/// written, because a shared shopping URL routinely carries a session id, a
/// cart id, the sharer's own referral code, search terms, and analytics that
/// identify them. None of it is needed to know which merchant this is — the
/// host alone answers that.
///
/// ## Why this is not encrypted, when the capture queue is
///
/// The capture queue holds raw bank messages, so it is AES-encrypted with a key
/// in the shared Keychain. This holds "somebody shared a link to shop.example".
/// It is bounded, drained on the next launch, and encrypting it would imply it
/// holds something it deliberately does not.
///
/// IMPORTANT: keep this file byte-identical in Runner and ShareBankMessage.
/// Swift targets do not share source automatically, and `RunnerTests` asserts
/// the copies match — the same contract `SharedCaptureStore.swift` carries.
enum SharedOfferIntentStore {
  static let appGroupIdentifier = "group.com.youssefsafwat.mali"

  private static let queueKey = "pending_offer_intents_v1"

  /// A hand-off buffer, not a queue: a user shares a link and opens the app. If
  /// dozens accumulate something is wrong, and the right response is to drop the
  /// oldest rather than grow without bound.
  private static let maxItems = 20

  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: appGroupIdentifier)
  }

  private static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  /// Reduces a URL to scheme + host + path.
  ///
  /// Rebuilt from components rather than trimmed from the original string —
  /// that is what guarantees no query parameter or fragment survives by
  /// accident. Returns nil for anything that is not a plain https URL with a
  /// host, including one carrying credentials: storing that would persist
  /// somebody's password.
  static func sanitize(_ url: URL) -> (url: String, host: String)? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    let scheme = components.scheme?.lowercased()
    guard scheme == "http" || scheme == "https" else { return nil }
    guard components.user == nil, components.password == nil else { return nil }
    guard var host = components.host?.lowercased(), !host.isEmpty else { return nil }
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    if host.hasSuffix(".") { host = String(host.dropLast()) }
    guard host.contains(".") else { return nil }

    components.scheme = "https"
    components.query = nil
    components.fragment = nil
    components.user = nil
    components.password = nil
    components.port = nil
    if components.path.isEmpty { components.path = "/" }
    guard let sanitized = components.string else { return nil }
    return (sanitized, host)
  }

  static func enqueue(url: URL) {
    guard let sanitized = sanitize(url), let defaults = defaults else { return }

    var items = load()
    // The same link twice in a row is a double-share, not two intents.
    if items.contains(where: { ($0["url"] as? String) == sanitized.url }) { return }

    items.append([
      "id": UUID().uuidString,
      "url": sanitized.url,
      "host": sanitized.host,
      "receivedAt": isoFormatter.string(from: Date()),
    ])
    while items.count > maxItems { items.removeFirst() }

    if let data = try? JSONSerialization.data(withJSONObject: items),
       let json = String(data: data, encoding: .utf8) {
      defaults.set(json, forKey: queueKey)
    }
  }

  /// Reads and clears. Unlike a capture, an offer intent has no durability
  /// requirement: losing one means the user taps the link again, whereas a lost
  /// bank message is a missing transaction.
  static func drain() -> String {
    let items = load()
    defaults?.removeObject(forKey: queueKey)
    guard let data = try? JSONSerialization.data(withJSONObject: items),
          let json = String(data: data, encoding: .utf8) else {
      return "[]"
    }
    return json
  }

  private static func load() -> [[String: Any]] {
    guard let json = defaults?.string(forKey: queueKey),
          let data = json.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      // Corrupt store: drop it. Nothing here is worth recovering, and a parse
      // that throws on every launch would be worse than an empty buffer.
      return []
    }
    return parsed
  }
}
