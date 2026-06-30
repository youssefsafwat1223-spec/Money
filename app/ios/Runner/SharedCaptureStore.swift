import CryptoKit
import Foundation

/// Shared store between the Flutter host app, the Share Extension, and the
/// "Process Bank SMS" App Intent.
///
/// The store is intentionally App Group based so App Intents can run without
/// opening Flutter. Flutter drains the FIFO queue when the host app is active.
///
/// IMPORTANT: keep this file identical in Runner, ShareBankMessage, and
/// BankMessageShortcuts. Swift targets do not share source automatically.
enum SharedCaptureStore {
  static let appGroupIdentifier = "group.com.youssefsafwat.mali"
  static let pendingMessagesNotificationName =
    "com.youssefsafwat.mali.pendingBankMessages"

  private static let queueKey = "pending_bank_messages_v2"
  private static let legacyKey = "pending_bank_message_text"
  private static let pendingCountKey = "pending_bank_messages_count"
  private static let latestPayloadIDKey = "pending_bank_messages_latest_id"

  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: appGroupIdentifier)
  }

  private static let isoFormatter = ISO8601DateFormatter()

  enum CaptureStatus: String, Codable {
    case pending
    case failed
  }

  enum EnqueueResult {
    case enqueued(Payload)
    case duplicate(Payload)
    case failed(String)
  }

  /// Codable payload consumed by Flutter through the native capture channel.
  struct Payload: Codable {
    let id: String?
    let text: String
    let sender: String?
    let senderName: String?
    let senderId: String?
    let source: String?
    let receivedAt: String?
    let locale: String?
    let status: String?
    let failureReason: String?
    let createdAt: String?
  }

  /// Adds a captured bank message to the shared queue.
  ///
  /// Duplicate prevention is scoped to pending native payloads only. Transaction
  /// duplicate detection remains in Flutter where the domain model lives.
  @discardableResult
  static func enqueue(
    text: String,
    sender: String? = nil,
    senderName: String? = nil,
    senderID: String? = nil,
    source: String? = nil,
    receivedAt: Date = Date(),
    localeIdentifier: String? = nil
  ) -> EnqueueResult {
    guard defaults != nil else {
      return .failed("App Group storage is unavailable.")
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failed("SMS text is empty.")
    }

    let cleanSender = clean(sender)
    let cleanSenderName = clean(senderName)
    let cleanSenderID = clean(senderID)
    let cleanSource = clean(source)
    let receivedAtString = isoFormatter.string(from: receivedAt)
    let createdAtString = isoFormatter.string(from: Date())
    let locale = clean(localeIdentifier) ?? Locale.autoupdatingCurrent.identifier
    let payloadID = makePayloadID(
      text: trimmed,
      sender: cleanSender,
      senderName: cleanSenderName,
      senderID: cleanSenderID,
      source: cleanSource,
      receivedAt: receivedAtString
    )
    let payload = Payload(
      id: payloadID,
      text: trimmed,
      sender: cleanSender ?? cleanSenderID ?? cleanSenderName,
      senderName: cleanSenderName,
      senderId: cleanSenderID,
      source: cleanSource,
      receivedAt: receivedAtString,
      locale: locale,
      status: CaptureStatus.pending.rawValue,
      failureReason: nil,
      createdAt: createdAtString
    )

    var queue = loadQueue()
    if let existing = queue.first(where: { $0.id == payloadID }) {
      notifyPendingMessagesAvailable()
      return .duplicate(existing)
    }

    queue.append(payload)
    guard saveQueue(queue) else {
      return .failed("Could not save the SMS payload.")
    }
    return .enqueued(payload)
  }

  /// Backward-compatible single store used by older call sites.
  @discardableResult
  static func store(text: String) -> EnqueueResult {
    enqueue(text: text, sender: nil)
  }

  /// Returns true when the App Group queue currently has pending messages.
  static func hasPendingMessages() -> Bool {
    !loadQueue().isEmpty ||
      ((defaults?.string(forKey: legacyKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty) == false)
  }

  /// Drains the whole queue plus any legacy value and returns a JSON array.
  ///
  /// The queue is removed only after JSON encoding succeeds so messages are not
  /// lost if encoding fails.
  static func consumePendingPayloadsJSON() -> String? {
    var queue = loadQueue()
    if let legacy = defaults?.string(forKey: legacyKey),
       !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let receivedAt = isoFormatter.string(from: Date())
      queue.append(Payload(
        id: makePayloadID(
          text: legacy,
          sender: nil,
          senderName: nil,
          senderID: nil,
          source: "legacy",
          receivedAt: receivedAt
        ),
        text: legacy,
        sender: nil,
        senderName: nil,
        senderId: nil,
        source: "legacy",
        receivedAt: receivedAt,
        locale: Locale.autoupdatingCurrent.identifier,
        status: CaptureStatus.pending.rawValue,
        failureReason: nil,
        createdAt: receivedAt
      ))
    }
    guard !queue.isEmpty else {
      updatePendingMetadata([])
      return nil
    }
    guard let data = try? JSONEncoder().encode(queue),
          let json = String(data: data, encoding: .utf8) else {
      return nil
    }
    defaults?.removeObject(forKey: queueKey)
    defaults?.removeObject(forKey: legacyKey)
    updatePendingMetadata([])
    defaults?.synchronize()
    return json
  }

  /// Backward-compatible single consume that returns the oldest text only.
  static func consumePendingText() -> String? {
    var queue = loadQueue()
    if queue.isEmpty {
      if let legacy = defaults?.string(forKey: legacyKey),
         !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        defaults?.removeObject(forKey: legacyKey)
        updatePendingMetadata([])
        defaults?.synchronize()
        return legacy
      }
      updatePendingMetadata([])
      return nil
    }
    let first = queue.removeFirst()
    _ = saveQueue(queue)
    return first.text
  }

  private static func loadQueue() -> [Payload] {
    guard let data = defaults?.data(forKey: queueKey),
          let queue = try? JSONDecoder().decode([Payload].self, from: data) else {
      return []
    }
    return queue
  }

  @discardableResult
  private static func saveQueue(_ queue: [Payload]) -> Bool {
    if queue.isEmpty {
      defaults?.removeObject(forKey: queueKey)
    } else {
      guard let data = try? JSONEncoder().encode(queue) else {
        return false
      }
      defaults?.set(data, forKey: queueKey)
    }
    updatePendingMetadata(queue)
    defaults?.synchronize()
    if !queue.isEmpty {
      notifyPendingMessagesAvailable()
    }
    return true
  }

  private static func updatePendingMetadata(_ queue: [Payload]) {
    if queue.isEmpty {
      defaults?.removeObject(forKey: pendingCountKey)
      defaults?.removeObject(forKey: latestPayloadIDKey)
    } else {
      defaults?.set(queue.count, forKey: pendingCountKey)
      defaults?.set(queue.last?.id, forKey: latestPayloadIDKey)
    }
  }

  private static func notifyPendingMessagesAvailable() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(pendingMessagesNotificationName as CFString),
      nil,
      nil,
      true
    )
  }

  private static func clean(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed?.isEmpty ?? true) ? nil : trimmed
  }

  private static func makePayloadID(
    text: String,
    sender: String?,
    senderName: String?,
    senderID: String?,
    source: String?,
    receivedAt: String
  ) -> String {
    let raw = [
      text,
      sender ?? "",
      senderName ?? "",
      senderID ?? "",
      source ?? "",
      receivedAt
    ].joined(separator: "|")
    let digest = SHA256.hash(data: Data(raw.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
