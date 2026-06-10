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
}
