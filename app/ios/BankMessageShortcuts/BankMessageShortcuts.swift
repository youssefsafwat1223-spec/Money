import AppIntents
import Foundation
import UserNotifications

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

  /// Keeps the app from opening by default on pre-iOS 26 systems while still
  /// letting Shortcuts expose its normal "Show When Run" control.
  static var openAppWhenRun: Bool = false

  @available(iOS 26.0, *)
  static var supportedModes: IntentModes {
    [.background, .foreground(.dynamic)]
  }

  static var parameterSummary: some ParameterSummary {
    Summary("Process \(\.$smsText) from \(\.$senderName)")
  }

  @Parameter(
    title: "SMS Text",
    description: "The bank SMS text to process.",
    inputOptions: String.IntentInputOptions(multiline: true)
  )
  var smsText: String

  @Parameter(title: "Sender", description: "The sender shown by Messages.")
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

  func perform() async -> some IntentResult {
    let receivedAt = dateReceived ?? Date()
    let request = BankSMSCaptureRequest(
      smsText: smsText,
      senderName: senderName,
      senderID: senderID,
      receivedAt: receivedAt,
      localeIdentifier: deviceLocale
    )
    let service = BankSMSCaptureService()
    let config = SharedCaptureStore.backendConfig()

    if config.canUseBackend {
      do {
        let response = try await BackendCaptureClient(config: config).process(
          request,
          payloadID: SharedCaptureStore.makePayloadID(
            text: smsText.trimmingCharacters(in: .whitespacesAndNewlines),
            sender: firstNonEmpty(senderID, senderName),
            senderName: senderName,
            senderID: senderID,
            source: "ios_shortcut",
            receivedAt: SharedCaptureStore.isoString(from: receivedAt)
          )
        )
        _ = try service.capture(
          request,
          status: .sent,
          sentAt: Date(),
          failureReason: nil
        )
        if !response.pushSent {
          await scheduleNotification(response.notification)
        }
        return .result()
      } catch {
        _ = try? service.capture(
          request,
          status: .pending,
          sentAt: nil,
          failureReason: "\(error)"
        )
        await scheduleGenericFallbackNotification()
        return .result()
      }
    }

    let captured = (try? service.capture(request)) != nil
    if captured {
      await scheduleGenericFallbackNotification()
    }
    return .result()
  }

  private func scheduleNotification(_ notification: BackendNotification) async {
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.sound = .default

    let notifRequest = UNNotificationRequest(
      identifier: "capture_backend_\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
    try? await UNUserNotificationCenter.current().add(notifRequest)
  }

  private func scheduleGenericFallbackNotification() async {
    let sender = firstNonEmpty(senderName, senderID)
    await scheduleNotification(BackendNotification(
      title: "قِرش رصد رسالة بنك",
      body: sender == nil
        ? "تم استلام رسالة بنكية. افتح قِرش لمراجعتها."
        : "تم استلام رسالة من \(sender!). افتح قِرش لمراجعتها.",
      type: "received"
    ))
  }

  private func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      if let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines),
         !clean.isEmpty {
        return clean
      }
    }
    return nil
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
  func capture(
    _ request: BankSMSCaptureRequest,
    status: SharedCaptureStore.CaptureStatus = .pending,
    sentAt: Date? = nil,
    failureReason: String? = nil
  ) throws -> SharedCaptureStore.EnqueueResult {
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
      source: "ios_shortcut",
      receivedAt: request.receivedAt ?? Date(),
      localeIdentifier: (locale?.isEmpty ?? true) ? fallbackLocale : locale,
      status: status,
      sentAt: sentAt,
      failureReason: failureReason
    )

    #if DEBUG
      debugPrint(
        "[MaliShortcut] received smsLength=\(trimmedText.count) " +
        "senderNameSet=\(!(request.senderName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)) " +
        "senderIDSet=\(!(request.senderID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)) " +
        "receivedAt=\((request.receivedAt ?? Date()).ISO8601Format()) source=ios_shortcut"
      )
    #endif

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
    localeIdentifier: String?,
    status: SharedCaptureStore.CaptureStatus,
    sentAt: Date?,
    failureReason: String?
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
    localeIdentifier: String?,
    status: SharedCaptureStore.CaptureStatus,
    sentAt: Date?,
    failureReason: String?
  ) -> SharedCaptureStore.EnqueueResult {
    SharedCaptureStore.enqueue(
      text: text,
      sender: senderID ?? senderName,
      senderName: senderName,
      senderID: senderID,
      source: source,
      receivedAt: receivedAt,
      localeIdentifier: localeIdentifier,
      status: status,
      sentAt: sentAt,
      failureReason: failureReason
    )
  }
}

// MARK: - Backend capture client

@available(iOS 16.0, *)
struct BackendNotification {
  let title: String
  let body: String
  let type: String
}

@available(iOS 16.0, *)
struct BackendCaptureResponse {
  let notification: BackendNotification
  let pushSent: Bool
}

@available(iOS 16.0, *)
enum BackendCaptureError: Error {
  case invalidConfig
  case invalidURL
  case http(Int)
  case malformedResponse
}

@available(iOS 16.0, *)
struct BackendCaptureClient {
  let config: SharedCaptureStore.BackendConfig

  func process(
    _ request: BankSMSCaptureRequest,
    payloadID: String
  ) async throws -> BackendCaptureResponse {
    guard config.canUseBackend,
          let backendURL = config.backendURL,
          let installID = config.installID,
          let deviceSecret = config.deviceSecret,
          let anonKey = config.anonKey else {
      throw BackendCaptureError.invalidConfig
    }
    guard let url = URL(string: "\(backendURL)/functions/v1/process-ios-sms") else {
      throw BackendCaptureError.invalidURL
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = 8
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
    urlRequest.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
    let sanitized = Self.sanitize(request.smsText)
    let body: [String: Any] = [
      "payloadId": payloadID,
      "installId": installID,
      "deviceSecret": deviceSecret,
      "smsText": sanitized,
      "sanitizedText": sanitized,
      "sender": request.senderID ?? request.senderName ?? "",
      "senderName": request.senderName ?? "",
      "senderId": request.senderID ?? "",
      "receivedAt": SharedCaptureStore.isoString(from: request.receivedAt ?? Date()),
      "locale": request.localeIdentifier ?? Locale.autoupdatingCurrent.identifier,
      "source": "ios_shortcut",
      "allowAi": UserDefaults(suiteName: SharedCaptureStore.appGroupIdentifier)?
        .bool(forKey: "ai_consent_granted") ?? false
    ]
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard statusCode == 200 else {
      throw BackendCaptureError.http(statusCode)
    }
    guard
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let capture = json["capture"] as? [String: Any],
      let notification = capture["notification"] as? [String: Any],
      let title = notification["title"] as? String,
      let body = notification["body"] as? String
    else {
      throw BackendCaptureError.malformedResponse
    }
    return BackendCaptureResponse(notification: BackendNotification(
      title: title,
      body: body,
      type: notification["type"] as? String ?? "received"
    ), pushSent: json["pushSent"] as? Bool ?? false)
  }

  private static func sanitize(_ text: String) -> String {
    var value = text
    let rules: [(String, String)] = [
      (#"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b"#, "[CARD]"),
      (#"\b05\d{8}\b"#, "[PHONE]"),
      (#"\b01[0125]\d{8}\b"#, "[PHONE]"),
      (#"\+\d{7,15}\b"#, "[PHONE]"),
      (#"\b\d{10,20}\b"#, "[ACCOUNT]")
    ]
    for (pattern, replacement) in rules {
      guard let regex = try? NSRegularExpression(pattern: pattern) else {
        continue
      }
      value = regex.stringByReplacingMatches(
        in: value,
        range: NSRange(location: 0, length: (value as NSString).length),
        withTemplate: replacement
      )
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - Shared rule-based preview parser

/// Mirrors `lib/engine/parser/shared_preview_parser.dart` and reads the SAME
/// `assets/catalog/parser_rules.json` that Flutter bundles — one rules file,
/// two runtimes, identical semantics. Any change to the algorithm here must
/// be applied to the Dart mirror too; the Dart tests over the embedded
/// examples are the contract for both.
@available(iOS 16.0, *)
enum PreviewOutcome {
  case debit
  case credit
  case unknown
  case ignored
}

@available(iOS 16.0, *)
struct PreviewResult {
  let outcome: PreviewOutcome
  let amount: Double?
  let currency: String?
  let merchant: String?
  let last4: String?

  /// Detailed notification only when type + amount + currency are all clear.
  var isHighConfidence: Bool {
    (outcome == .debit || outcome == .credit) && amount != nil && currency != nil
  }
}

@available(iOS 16.0, *)
final class PreviewParser {
  /// nil when the rules file can't be found/parsed — callers fall back to the
  /// generic notification text.
  static let shared: PreviewParser? = loadBundledRules()

  private let currencyReplacements: [(NSRegularExpression, String)]
  private let decimalMarks: [String]
  private let thousandsMarks: [String]
  private let currencyPattern: NSRegularExpression
  private let ignoreKeywords: [String]
  private let debitKeywords: [String]
  private let creditKeywords: [String]
  private let amountPatterns: [NSRegularExpression]
  private let merchantPatterns: [NSRegularExpression]
  private let merchantStopPattern: NSRegularExpression
  private let last4Patterns: [NSRegularExpression]
  private let thousandsBetweenDigits: NSRegularExpression

  private init?(json: [String: Any]) {
    func regex(_ pattern: String) -> NSRegularExpression? {
      try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
    func regexes(_ value: Any?) -> [NSRegularExpression]? {
      guard let patterns = value as? [String] else { return nil }
      let compiled = patterns.compactMap(regex)
      return compiled.count == patterns.count ? compiled : nil
    }

    guard
      let normalization = json["normalization"] as? [String: Any],
      let replacementItems = normalization["currencyReplacements"] as? [[String: String]],
      let decimalMarks = normalization["decimalMarks"] as? [String],
      let thousandsMarks = normalization["thousandsMarks"] as? [String],
      let currencyPatternString = json["currencyPattern"] as? String,
      let currencyPattern = regex(currencyPatternString),
      let ignoreKeywords = json["ignoreKeywords"] as? [String],
      let debitKeywords = json["debitKeywords"] as? [String],
      let creditKeywords = json["creditKeywords"] as? [String],
      let amountPatterns = regexes(json["amountPatterns"]),
      let merchantPatterns = regexes(json["merchantPatterns"]),
      let merchantStopString = json["merchantStopPattern"] as? String,
      let merchantStopPattern = regex(merchantStopString),
      let last4Patterns = regexes(json["last4Patterns"]),
      let thousandsBetweenDigits = regex("(\\d),(\\d)")
    else { return nil }

    var replacements: [(NSRegularExpression, String)] = []
    for item in replacementItems {
      guard let pattern = item["pattern"], let replacement = item["replacement"],
            let compiled = regex(pattern) else { return nil }
      replacements.append((compiled, replacement))
    }

    self.currencyReplacements = replacements
    self.decimalMarks = decimalMarks
    self.thousandsMarks = thousandsMarks
    self.currencyPattern = currencyPattern
    self.ignoreKeywords = ignoreKeywords
    self.debitKeywords = debitKeywords
    self.creditKeywords = creditKeywords
    self.amountPatterns = amountPatterns
    self.merchantPatterns = merchantPatterns
    self.merchantStopPattern = merchantStopPattern
    self.last4Patterns = last4Patterns
    self.thousandsBetweenDigits = thousandsBetweenDigits
  }

  /// Locates the Flutter-bundled rules file. Works both when the intent runs
  /// inside the main app (Bundle.main = Runner.app) and inside the extension
  /// (Bundle.main = Runner.app/PlugIns|Extensions/BankMessageShortcuts.appex).
  private static func loadBundledRules() -> PreviewParser? {
    let assetPath =
      "Frameworks/App.framework/flutter_assets/assets/catalog/parser_rules.json"
    let bundleURL = Bundle.main.bundleURL
    let candidates = [
      bundleURL,
      bundleURL.deletingLastPathComponent().deletingLastPathComponent(),
    ]
    for base in candidates {
      let url = base.appendingPathComponent(assetPath)
      guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data)
              as? [String: Any]
      else { continue }
      return PreviewParser(json: json)
    }
    return nil
  }

  func parse(_ text: String) -> PreviewResult {
    let normalized = normalize(text)
    let lower = normalized.lowercased()

    if ignoreKeywords.contains(where: { lower.contains($0) }) {
      return PreviewResult(
        outcome: .ignored, amount: nil, currency: nil, merchant: nil, last4: nil
      )
    }

    return PreviewResult(
      outcome: detectOutcome(in: lower),
      amount: firstGroup(amountPatterns, in: normalized).flatMap(Double.init),
      currency: extractCurrency(from: normalized),
      merchant: extractMerchant(from: normalized),
      last4: firstGroup(last4Patterns, in: normalized)
    )
  }

  static func format(_ amount: Double) -> String {
    amount == amount.rounded(.towardZero)
      ? String(Int(amount))
      : String(format: "%.2f", amount)
  }

  private func normalize(_ input: String) -> String {
    var text = Self.normalizeDigits(input)
    for mark in decimalMarks {
      text = text.replacingOccurrences(of: mark, with: ".")
    }
    for mark in thousandsMarks {
      text = text.replacingOccurrences(of: mark, with: "")
    }
    for (pattern, replacement) in currencyReplacements {
      text = pattern.stringByReplacingMatches(
        in: text,
        range: NSRange(location: 0, length: (text as NSString).length),
        withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
      )
    }
    // فواصل الآلاف بين رقمين: 12,500.00 → 12500.00 (حلقة لأن التطابقات تتداخل).
    while thousandsBetweenDigits.firstMatch(
      in: text, range: NSRange(location: 0, length: (text as NSString).length)
    ) != nil {
      text = thousandsBetweenDigits.stringByReplacingMatches(
        in: text,
        range: NSRange(location: 0, length: (text as NSString).length),
        withTemplate: "$1$2"
      )
    }
    return text
  }

  private static func normalizeDigits(_ input: String) -> String {
    let arabicIndicZero: UInt32 = 0x0660
    let extendedArabicIndicZero: UInt32 = 0x06F0
    var output = String.UnicodeScalarView()
    for scalar in input.unicodeScalars {
      if scalar.value >= arabicIndicZero, scalar.value <= arabicIndicZero + 9 {
        output.append(Unicode.Scalar(0x30 + (scalar.value - arabicIndicZero))!)
      } else if scalar.value >= extendedArabicIndicZero,
                scalar.value <= extendedArabicIndicZero + 9 {
        output.append(
          Unicode.Scalar(0x30 + (scalar.value - extendedArabicIndicZero))!)
      } else {
        output.append(scalar)
      }
    }
    return String(output)
  }

  private func detectOutcome(in lower: String) -> PreviewOutcome {
    let debitIndex = Self.earliestIndex(of: debitKeywords, in: lower)
    let creditIndex = Self.earliestIndex(of: creditKeywords, in: lower)
    switch (debitIndex, creditIndex) {
    case (nil, nil): return .unknown
    case (_, nil): return .debit
    case (nil, _): return .credit
    case let (debit?, credit?):
      // الاثنان موجودان — الأسبق في النص يحسم (وعند التساوي: خصم).
      return debit <= credit ? .debit : .credit
    }
  }

  private static func earliestIndex(
    of keywords: [String], in lower: String
  ) -> String.Index? {
    var earliest: String.Index?
    for keyword in keywords {
      guard let range = lower.range(of: keyword) else { continue }
      if earliest == nil || range.lowerBound < earliest! {
        earliest = range.lowerBound
      }
    }
    return earliest
  }

  private func extractCurrency(from normalized: String) -> String? {
    firstGroupMatch(currencyPattern, in: normalized)?.uppercased()
  }

  private func extractMerchant(from normalized: String) -> String? {
    guard let raw = firstGroup(merchantPatterns, in: normalized) else {
      return nil
    }
    var merchant = merchantStopPattern.stringByReplacingMatches(
      in: raw,
      range: NSRange(location: 0, length: (raw as NSString).length),
      withTemplate: ""
    )
    let edgeTrim = CharacterSet(charactersIn: " \t\n\r.,:;؛*-")
    merchant = merchant.trimmingCharacters(in: edgeTrim)
    return merchant.isEmpty ? nil : merchant
  }

  private func firstGroup(
    _ patterns: [NSRegularExpression], in text: String
  ) -> String? {
    for pattern in patterns {
      if let value = firstGroupMatch(pattern, in: text) {
        return value
      }
    }
    return nil
  }

  private func firstGroupMatch(
    _ pattern: NSRegularExpression, in text: String
  ) -> String? {
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    guard let match = pattern.firstMatch(in: text, range: range),
          match.numberOfRanges > 1,
          match.range(at: 1).location != NSNotFound
    else { return nil }
    let value = nsText.substring(with: match.range(at: 1))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
