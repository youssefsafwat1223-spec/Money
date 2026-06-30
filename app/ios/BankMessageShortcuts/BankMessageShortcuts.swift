import AppIntents
import Foundation

/// App Intent exposed to the Shortcuts app as "Process Bank SMS".
///
/// Accepts the raw bank SMS text, stores it in the shared App Group queue, and
/// launches the host app so Flutter can run the existing parsing pipeline
/// (ParserEngine + AddTransactionUseCase) on resume.
@available(iOS 16.0, *)
struct PostBankStatusIntent: AppIntent {
  static var title: LocalizedStringResource = "Process Bank SMS"

  static var description = IntentDescription(
    "Process a bank SMS in Mali so it parses the amount, merchant and category and adds the transaction."
  )

  /// false = silent background capture; app stays closed or in background.
  /// The message is drained on next foreground via AppLifecycleListener.onResume.
  static var openAppWhenRun: Bool = false

  @Parameter(
    title: "SMS Text",
    description: "The raw bank SMS text.",
    inputOptions: String.IntentInputOptions(multiline: true)
  )
  var message: String

  static var parameterSummary: some ParameterSummary {
    Summary("Process Bank SMS") {
      \.$message
    }
  }

  func perform() async throws -> some IntentResult {
    SharedCaptureStore.enqueue(text: message, sender: nil)
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
        "Process Bank SMS with \(.applicationName)",
        "Add a bank message to \(.applicationName)",
        "Send bank SMS to \(.applicationName)"
      ],
      shortTitle: "Process Bank SMS",
      systemImageName: "creditcard"
    )
  }
}
