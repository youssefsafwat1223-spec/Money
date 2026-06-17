import AppIntents
import Foundation

/// App Intent exposed to the Shortcuts app as "Post Bank Status".
///
/// Accepts the raw bank SMS text and an optional sender name, stores them in the
/// shared App Group queue, and launches the host app so Flutter can run the
/// existing parsing pipeline (ParserEngine + AddTransactionUseCase) on resume.
@available(iOS 16.0, *)
struct PostBankStatusIntent: AppIntent {
  static var title: LocalizedStringResource = "Post Bank Status"

  static var description = IntentDescription(
    "Send a bank SMS to Mali so it parses the amount, merchant and category and adds the transaction."
  )

  /// false = silent background capture; app stays closed or in background.
  /// The message is drained on next foreground via AppLifecycleListener.onResume.
  static var openAppWhenRun: Bool = false

  @Parameter(
    title: "Message",
    description: "The raw bank SMS text.",
    inputOptions: String.IntentInputOptions(multiline: true)
  )
  var message: String

  @Parameter(
    title: "Sender",
    description: "Optional sender name or short code (e.g. the bank name)."
  )
  var sender: String?

  static var parameterSummary: some ParameterSummary {
    Summary("Post \(\.$message) from \(\.$sender) to Mali")
  }

  func perform() async throws -> some IntentResult {
    SharedCaptureStore.enqueue(text: message, sender: sender)
    return .result()
  }
}

/// Registers the intent with the Shortcuts app and Siri.
@available(iOS 16.0, *)
struct BankMessageShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PostBankStatusIntent(),
      phrases: [
        "Post Bank Status to \(.applicationName)",
        "Add a bank message to \(.applicationName)",
        "Send bank SMS to \(.applicationName)"
      ],
      shortTitle: "Post Bank Status",
      systemImageName: "creditcard"
    )
  }
}
