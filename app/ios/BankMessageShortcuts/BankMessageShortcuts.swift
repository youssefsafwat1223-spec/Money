import AppIntents
import Foundation

struct AddBankMessageIntent: AppIntent {
  static var title: LocalizedStringResource = "أضف رسالة بنك"
  static var description = IntentDescription("يمرّر نص رسالة البنك إلى التطبيق ليضيفها عبر نفس مسار الالتقاط.")

  @Parameter(title: "نص الرسالة")
  var messageText: String

  func perform() async throws -> some IntentResult {
    SharedCaptureStore.store(text: messageText)
    return .result()
  }
}
