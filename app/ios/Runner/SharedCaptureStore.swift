import Foundation

/// Shared store between the Flutter host app, the Share Extension, and the
/// "Post Bank Status" App Intent. Persists captured bank messages in the App
/// Group container as a FIFO queue so multiple messages are never lost.
///
/// IMPORTANT: must be identical in all three targets (Runner, ShareBankMessage,
/// BankMessageShortcuts) — Swift targets do not share source automatically.
enum SharedCaptureStore {
  static let appGroupIdentifier = "group.com.youssefsafwat.mali.shared"
  private static let queueKey = "pending_bank_messages_v2"
  // Legacy single-value key kept for backward compatibility.
  private static let legacyKey = "pending_bank_message_text"

  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: appGroupIdentifier)
  }

  struct Payload: Codable {
    let text: String
    let sender: String?
  }

  /// Adds a captured bank message to the queue.
  static func enqueue(text: String, sender: String? = nil) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let cleanSender = sender?.trimmingCharacters(in: .whitespacesAndNewlines)
    var queue = loadQueue()
    queue.append(Payload(text: trimmed, sender: (cleanSender?.isEmpty ?? true) ? nil : cleanSender))
    saveQueue(queue)
  }

  /// Backward-compatible single store (no sender).
  static func store(text: String) {
    enqueue(text: text, sender: nil)
  }

  /// Drains the whole queue (plus any legacy value) and returns it as a JSON
  /// array string: [{"text":"...","sender":"..."}]. Returns nil if empty.
  static func consumePendingPayloadsJSON() -> String? {
    var queue = loadQueue()
    if let legacy = defaults?.string(forKey: legacyKey),
       !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      queue.append(Payload(text: legacy, sender: nil))
      defaults?.removeObject(forKey: legacyKey)
    }
    guard !queue.isEmpty else { return nil }
    defaults?.removeObject(forKey: queueKey)
    defaults?.synchronize()
    guard let data = try? JSONEncoder().encode(queue),
          let json = String(data: data, encoding: .utf8) else {
      return nil
    }
    return json
  }

  /// Backward-compatible single consume (returns the oldest text only).
  static func consumePendingText() -> String? {
    var queue = loadQueue()
    if queue.isEmpty {
      if let legacy = defaults?.string(forKey: legacyKey),
         !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        defaults?.removeObject(forKey: legacyKey)
        defaults?.synchronize()
        return legacy
      }
      return nil
    }
    let first = queue.removeFirst()
    saveQueue(queue)
    return first.text
  }

  private static func loadQueue() -> [Payload] {
    guard let data = defaults?.data(forKey: queueKey),
          let queue = try? JSONDecoder().decode([Payload].self, from: data) else {
      return []
    }
    return queue
  }

  private static func saveQueue(_ queue: [Payload]) {
    if queue.isEmpty {
      defaults?.removeObject(forKey: queueKey)
    } else if let data = try? JSONEncoder().encode(queue) {
      defaults?.set(data, forKey: queueKey)
    }
    defaults?.synchronize()
  }
}
