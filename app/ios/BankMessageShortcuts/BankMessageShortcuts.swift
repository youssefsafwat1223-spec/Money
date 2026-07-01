import AppIntents
import Foundation

/// App Intent exposed to Shortcuts as "Process Bank SMS".
///
/// The Swift type name is kept for backward compatibility with existing
/// automations; the user-facing title is the localized Shortcuts action name.
@available(iOS 16.0, *)
struct PostBankStatusIntent: AppIntent {
  static var title: LocalizedStringResource = "Process Bank SMS"

  static var description = IntentDescription(
    "Processes a bank SMS and imports the transaction into Mali."
  )

  /// Keeps Shortcut automations silent whenever iOS allows it. The intent only
  /// captures the payload into the App Group; Flutter drains it when available.
  static var openAppWhenRun: Bool = false

  static var parameterSummary: some ParameterSummary {
    Summary("Process \(\.$smsText)")
  }

  @Parameter(
    title: "SMS Text",
    description: "The bank SMS text to process.",
    inputOptions: String.IntentInputOptions(multiline: true)
  )
  var smsText: String

  @Parameter(
    title: "Sender Name",
    description: "The sender name shown by Messages."
  )
  var senderName: String?

  @Parameter(
    title: "Sender ID",
    description: "The bank sender identifier or short code."
  )
  var senderID: String?

  @Parameter(
    title: "Date Received",
    description: "When the SMS was received."
  )
  var dateReceived: Date?

  @Parameter(
    title: "Device Locale",
    description: "The device locale identifier, such as en_US or ar_SA."
  )
  var deviceLocale: String?

  func perform() async throws -> some IntentResult {
    let request = BankSMSCaptureRequest(
      smsText: smsText,
      senderName: senderName,
      senderID: senderID,
      receivedAt: dateReceived,
      localeIdentifier: deviceLocale
    )
    _ = try BankSMSCaptureService().capture(request)
    return .result()
  }
}

/// Registers Mali shortcuts with the Shortcuts app and Siri.
struct BankMessageShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PostBankStatusIntent(),
      phrases: [
        "Process Bank SMS in \(.applicationName)",
        "Process Bank SMS with \(.applicationName)",
        "Import bank SMS in \(.applicationName)",
        "Add transaction from SMS in \(.applicationName)",
        "Log bank expense in \(.applicationName)",
        "Track bank transaction in \(.applicationName)",
        "Send bank SMS to \(.applicationName)"
      ],
      shortTitle: "Process Bank SMS",
      systemImageName: "creditcard"
    )
  }
}

/// Immutable input model used by App Intents before writing to shared storage.
///
/// Keeping this separate from the intent makes future intents such as Add
/// Transaction or Quick Expense able to reuse the same capture pipeline.
@available(iOS 16.0, *)
struct BankSMSCaptureRequest {
  let smsText: String
  let senderName: String?
  let senderID: String?
  let receivedAt: Date?
  let localeIdentifier: String?
}

/// Intent-facing capture service.
///
/// The service intentionally avoids Flutter APIs. App extensions should stay
/// small, deterministic, and independent from the host app UI process.
@available(iOS 16.0, *)
struct BankSMSCaptureService {
  private let queue: CaptureQueueWriting

  init(queue: CaptureQueueWriting = SharedCaptureStoreWriter()) {
    self.queue = queue
  }

  @discardableResult
  func capture(_ request: BankSMSCaptureRequest) throws -> SharedCaptureStore.EnqueueResult {
    let trimmedText = request.smsText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      throw ProcessBankSMSError.emptySMSText
    }

    let locale = request.localeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbackLocale = Locale.autoupdatingCurrent.identifier
    let result = queue.enqueue(
      text: trimmedText,
      senderName: request.senderName,
      senderID: request.senderID,
      source: "shortcut",
      receivedAt: request.receivedAt ?? Date(),
      localeIdentifier: (locale?.isEmpty ?? true) ? fallbackLocale : locale
    )

    if case let .failed(reason) = result {
      throw ProcessBankSMSError.captureFailed(reason)
    }
    return result
  }
}

/// Queue abstraction for dependency injection and future App Intent tests.
@available(iOS 16.0, *)
protocol CaptureQueueWriting {
  func enqueue(
    text: String,
    senderName: String?,
    senderID: String?,
    source: String?,
    receivedAt: Date,
    localeIdentifier: String?
  ) -> SharedCaptureStore.EnqueueResult
}

/// App Group backed queue writer used by production App Intents.
@available(iOS 16.0, *)
struct SharedCaptureStoreWriter: CaptureQueueWriting {
  func enqueue(
    text: String,
    senderName: String?,
    senderID: String?,
    source: String?,
    receivedAt: Date,
    localeIdentifier: String?
  ) -> SharedCaptureStore.EnqueueResult {
    SharedCaptureStore.enqueue(
      text: text,
      sender: senderID ?? senderName,
      senderName: senderName,
      senderID: senderID,
      source: source,
      receivedAt: receivedAt,
      localeIdentifier: localeIdentifier
    )
  }
}

/// Localized user-facing errors surfaced by Shortcuts.
@available(iOS 16.0, *)
enum ProcessBankSMSError: Error, LocalizedError {
  case emptySMSText
  case captureFailed(String)

  var errorDescription: String? {
    switch self {
    case .emptySMSText:
      return NSLocalizedString(
        "process_bank_sms_error_empty_sms",
        comment: "Shown when the App Intent receives empty SMS text."
      )
    case let .captureFailed(reason):
      let format = NSLocalizedString(
        "process_bank_sms_error_failed_format",
        comment: "Shown when the App Intent cannot save the SMS payload."
      )
      return String(format: format, reason)
    }
  }
}
