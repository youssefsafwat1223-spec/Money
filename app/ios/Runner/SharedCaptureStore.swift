import Foundation

enum SharedCaptureStore {
  static let appGroupIdentifier = "group.com.example.money_companion.shared"
  private static let pendingTextKey = "pending_bank_message_text"

  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: appGroupIdentifier)
  }

  static func store(text: String) {
    defaults?.set(text, forKey: pendingTextKey)
    defaults?.synchronize()
  }

  static func consumePendingText() -> String? {
    guard let text = defaults?.string(forKey: pendingTextKey), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    defaults?.removeObject(forKey: pendingTextKey)
    defaults?.synchronize()
    return text
  }
}
