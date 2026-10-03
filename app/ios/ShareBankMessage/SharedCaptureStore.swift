import CryptoKit
import Darwin
import Foundation
import Security

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
  private static let cloudProcessingEnabledKey = "cloud_processing_enabled"
  private static let deviceSecretKey = "device_secret"
  private static let backendURLKey = "backend_url"
  private static let anonKeyKey = "backend_anon_key"
  private static let installIDKey = "install_id"
  private static let aiConsentGrantedKey = "ai_consent_granted"
  private static let apnsTokenKey = "apns_token"
  private static let apnsEnvironmentKey = "apns_environment"
  private static let pendingNotificationRoutesKey = "pending_notification_routes_v1"
  private static let notificationLogEventsKey = "pending_notification_log_events_v1"
  private static let queueLockFileName = "pending_bank_messages.lock"

  // MALI-031 — secret material lives in the shared Keychain, never UserDefaults.
  // `deviceSecretKC` is the device auth secret; `queueEncryptionKeyKC` is the
  // AES-256 key that encrypts the raw-SMS capture queue at rest.
  private static let deviceSecretKC = "device_secret"
  private static let queueEncryptionKeyKC = "capture_queue_key_v1"

  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: appGroupIdentifier)
  }

  private static let isoFormatter = ISO8601DateFormatter()

  enum CaptureStatus: String, Codable {
    case pending
    case pendingSend
    case sent
    case failed
  }

  /// Why a queue operation was refused. Every case means NOTHING was written:
  /// a failed operation never touches the stored queue blob (CAP-0).
  enum QueueError: Error {
    /// The App Group container or the cross-process lock inside it is unusable.
    case lockUnavailable
    /// The queue key could not be read or written (e.g.
    /// `errSecInteractionNotAllowed` before the first unlock).
    case keyUnavailable(OSStatus)
    /// A queue blob exists but cannot be decrypted/decoded (corrupt, or its key
    /// is gone). It is left in place and every write is refused until it is
    /// purged (sign-out); overwriting it would silently destroy recoverable
    /// captures.
    case unreadable
    case encodingFailed
  }

  /// Test seams (CAP-0), never set in production: the Keychain read of the
  /// queue key, and a forced lock failure.
  static var queueKeyReadOverride: (() -> (status: OSStatus, data: Data?))?
  static var lockUnavailableOverride = false

  struct BackendConfig {
    let cloudProcessingEnabled: Bool
    let installID: String?
    let deviceSecret: String?
    let backendURL: String?
    let anonKey: String?

    var canUseBackend: Bool {
      cloudProcessingEnabled &&
        !(installID?.isEmpty ?? true) &&
        !(deviceSecret?.isEmpty ?? true) &&
        !(backendURL?.isEmpty ?? true) &&
        !(anonKey?.isEmpty ?? true)
    }
  }

  struct NotificationRoutePayload: Codable {
    let payloadId: String?
    let transactionId: String?
    let smartInboxItemId: String?
    let notificationType: String?
    let source: String?
    let receivedAt: String?
    let notificationLogId: String?
    /// Banner action button tapped (nil for a plain banner tap).
    let action: String?
  }

  /// One notification lifecycle event, queued here until the host Flutter
  /// app can sync it to `notification_logs`
  /// (docs/NOTIFICATION_PIPELINE_AUDIT.md Phase 1). `notificationLogId` is
  /// the SAME id used for the whole notification's lifecycle — never
  /// regenerated between created/sent/failed/opened.
  struct NotificationLogEventPayload: Codable {
    let notificationLogId: String
    let eventType: String
    let channel: String
    let notificationType: String
    let relatedEntityType: String?
    let relatedEntityId: String?
    let errorCode: String?
    let errorReason: String?
    let occurredAt: String
  }

  enum EnqueueResult {
    case enqueued(Payload)
    case duplicate(Payload)
    /// The String is an INTERNAL diagnostic (never shown to the user, never
    /// contains SMS text); the kind selects the user-facing copy.
    case failed(String, kind: FailureKind)
  }

  /// Why a capture could not be saved, as far as the user needs to know.
  /// The technical reason is logged internally only; this picks the copy.
  enum FailureKind {
    case emptyText
    case storageUnavailable
    /// The Keychain refused access because the iPhone has not been unlocked
    /// since it restarted (errSecInteractionNotAllowed).
    case deviceLocked

    /// User-facing copy (approved, R9). Arabic when the device's preferred
    /// language is Arabic, English otherwise. Never carries technical text.
    var userMessage: String {
      let arabic = Locale.preferredLanguages.first?.lowercased().hasPrefix("ar") == true
      switch self {
      case .emptyText:
        return arabic
          ? "لم يصل نص رسالة البنك إلى قِرش. تأكد أن الاختصار يمرّر نص الرسالة، ثم حاول مرة أخرى."
          : "Qirsh didn't receive the bank message text. Make sure the Shortcut passes the message text, then try again."
      case .storageUnavailable:
        return arabic
          ? "تعذر الوصول إلى بيانات قِرش الآمنة. افتح قِرش ثم حاول مرة أخرى."
          : "Qirsh couldn't access its secure storage. Open Qirsh, then try again."
      case .deviceLocked:
        return arabic
          ? "تعذر حفظ الرسالة بأمان. افتح قفل الآيفون، ثم افتح قِرش وحاول مرة أخرى."
          : "Couldn't save the message securely. Unlock your iPhone, then open Qirsh and try again."
      }
    }
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
    let sentAt: String?
    let createdAt: String?
    /// True when the App Intent's Date Received parameter was missing and the
    /// receive time was inferred (R9). Optional so older builds still decode.
    let receivedAtInferred: Bool?
  }

  /// Adds a captured bank message to the shared queue.
  ///
  /// Duplicate prevention is scoped to pending native payloads only. Transaction
  /// duplicate detection remains in Flutter where the domain model lives.
  ///
  /// [notifyHost] is false only for Flutter's own re-enqueue of a message whose
  /// processing failed: posting the Darwin notification there would wake the
  /// host again immediately and loop drain → fail → re-enqueue → drain forever.
  @discardableResult
  static func enqueue(
    text: String,
    sender: String? = nil,
    senderName: String? = nil,
    senderID: String? = nil,
    source: String? = nil,
    receivedAt: Date = Date(),
    localeIdentifier: String? = nil,
    status: CaptureStatus = .pending,
    sentAt: Date? = nil,
    failureReason: String? = nil,
    payloadID: String? = nil,
    receivedAtInferred: Bool? = nil,
    notifyHost: Bool = true
  ) -> EnqueueResult {
    guard defaults != nil else {
      return .failed("App Group storage is unavailable.", kind: .storageUnavailable)
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failed("SMS text is empty.", kind: .emptyText)
    }

    let cleanSender = clean(sender)
    let cleanSenderName = clean(senderName)
    let cleanSenderID = clean(senderID)
    let cleanSource = clean(source)
    let receivedAtString = isoFormatter.string(from: receivedAt)
    let createdAtString = isoFormatter.string(from: Date())
    let locale = clean(localeIdentifier) ?? Locale.autoupdatingCurrent.identifier
    // A caller-supplied ID (the App Intent's backend payload ID) wins so the
    // queue entry and the processed_captures row always share one identity.
    let payloadID = payloadID ?? makePayloadID(
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
      status: status.rawValue,
      failureReason: clean(failureReason),
      sentAt: sentAt.map { isoFormatter.string(from: $0) },
      createdAt: createdAtString,
      receivedAtInferred: receivedAtInferred
    )

    do {
      return try withQueueLock {
        var queue = try loadQueue()
        if let existing = queue.first(where: { $0.id == payloadID }) {
          if notifyHost {
            notifyPendingMessagesAvailable()
          }
          return .duplicate(existing)
        }

        queue.append(payload)
        try saveQueue(queue, notifyHost: notifyHost)
        return .enqueued(payload)
      }
    } catch {
      var kind = FailureKind.storageUnavailable
      if case let QueueError.keyUnavailable(status) = error,
         status == errSecInteractionNotAllowed {
        kind = .deviceLocked
      }
      return .failed("Could not save the SMS payload (\(error)).", kind: kind)
    }
  }

  /// Backward-compatible single store used by older call sites.
  @discardableResult
  static func store(text: String) -> EnqueueResult {
    enqueue(text: text, sender: nil)
  }

  /// Updates one durable queue entry without changing its stable payload ID.
  @discardableResult
  static func updateStatus(
    payloadID: String,
    status: CaptureStatus,
    failureReason: String? = nil
  ) -> Bool {
    (try? withQueueLock { () throws -> Bool in
      var queue = try loadQueue()
      guard let index = queue.firstIndex(where: { $0.id == payloadID }) else {
        return false
      }
      let current = queue[index]
      queue[index] = Payload(
        id: current.id,
        text: current.text,
        sender: current.sender,
        senderName: current.senderName,
        senderId: current.senderId,
        source: current.source,
        receivedAt: current.receivedAt,
        locale: current.locale,
        status: status.rawValue,
        failureReason: clean(failureReason),
        sentAt: status == .sent ? isoFormatter.string(from: Date()) : current.sentAt,
        createdAt: current.createdAt,
        receivedAtInferred: current.receivedAtInferred
      )
      try saveQueue(queue, notifyHost: false)
      return true
    }) ?? false
  }

  /// Removes only a positively acknowledged payload; other queue entries stay.
  @discardableResult
  static func remove(payloadID: String) -> Bool {
    (try? withQueueLock { () throws -> Bool in
      var queue = try loadQueue()
      let before = queue.count
      queue.removeAll(where: { $0.id == payloadID })
      guard queue.count != before else { return false }
      try saveQueue(queue, notifyHost: false)
      return true
    }) ?? false
  }

  /// Returns true when the App Group queue currently has pending messages.
  static func hasPendingMessages() -> Bool {
    (try? loadQueue())?.isEmpty == false ||
      ((defaults?.string(forKey: legacyKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty) == false)
  }

  /// Returns the queue as JSON WITHOUT deleting anything (per-item lease,
  /// MALI-012). Dart acknowledges each payload individually via
  /// `remove(payloadID:)` only after its import committed — a kill between
  /// drain and import re-delivers exactly the unacknowledged remainder
  /// instead of losing the whole batch.
  ///
  /// Any legacy single-text value is first folded into the durable queue (so
  /// it gains a stable payload id and the same per-item lifecycle) before the
  /// legacy key is cleared.
  static func peekPendingPayloadsJSON() throws -> String? {
    try withQueueLock {
      var queue = try loadQueue()
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
          sentAt: nil,
          createdAt: receivedAt,
          receivedAtInferred: nil
        ))
        // Persist the fold first; only then clear the legacy key so the text
        // is never in neither place.
        try saveQueue(queue, notifyHost: false)
        defaults?.removeObject(forKey: legacyKey)
        defaults?.synchronize()
      }
      guard !queue.isEmpty else {
        updatePendingMetadata([])
        return nil
      }
      guard let data = try? JSONEncoder().encode(queue),
            let json = String(data: data, encoding: .utf8) else {
        return nil
      }
      return json
    }
  }

  /// Drains the whole queue plus any legacy value and returns a JSON array.
  ///
  /// The queue is removed only after JSON encoding succeeds so messages are not
  /// lost if encoding fails.
  static func consumePendingPayloadsJSON() throws -> String? {
    try withQueueLock {
      var queue = try loadQueue()
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
          sentAt: nil,
          createdAt: receivedAt,
          receivedAtInferred: nil
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
  }

  /// Backward-compatible single consume that returns the oldest text only.
  static func consumePendingText() throws -> String? {
    try withQueueLock {
      var queue = try loadQueue()
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
      try saveQueue(queue)
      return first.text
    }
  }

  static func backendConfig() -> BackendConfig {
    BackendConfig(
      cloudProcessingEnabled: defaults?.bool(forKey: cloudProcessingEnabledKey) ?? false,
      installID: clean(defaults?.string(forKey: installIDKey)),
      deviceSecret: migratedDeviceSecret(),
      backendURL: clean(defaults?.string(forKey: backendURLKey)),
      anonKey: clean(defaults?.string(forKey: anonKeyKey))
    )
  }

  /// The device secret from the shared Keychain. A legacy UserDefaults value is
  /// migrated into the Keychain once and then removed, so the secret is never
  /// left as a plaintext UserDefaults duplicate (MALI-031).
  private static func migratedDeviceSecret() -> String? {
    if let fromKeychain = clean(SharedKeychain.string(forKey: deviceSecretKC)) {
      return fromKeychain
    }
    if let legacy = clean(defaults?.string(forKey: deviceSecretKey)) {
      SharedKeychain.setString(legacy, forKey: deviceSecretKC)
      defaults?.removeObject(forKey: deviceSecretKey)
      defaults?.synchronize()
      return legacy
    }
    return nil
  }

  static func setBackendConfig(
    cloudProcessingEnabled: Bool,
    installID: String?,
    deviceSecret: String?,
    backendURL: String?,
    anonKey: String?,
    aiConsentGranted: Bool
  ) {
    defaults?.set(cloudProcessingEnabled, forKey: cloudProcessingEnabledKey)
    defaults?.set(aiConsentGranted, forKey: aiConsentGrantedKey)
    setOrRemove(installID, forKey: installIDKey)
    // MALI-031: device secret → shared Keychain only; never a UserDefaults
    // duplicate. Any legacy plaintext value is removed.
    if let secret = clean(deviceSecret) {
      SharedKeychain.setString(secret, forKey: deviceSecretKC)
    } else {
      SharedKeychain.remove(forKey: deviceSecretKC)
    }
    defaults?.removeObject(forKey: deviceSecretKey)
    setOrRemove(backendURL, forKey: backendURLKey)
    setOrRemove(anonKey, forKey: anonKeyKey)
    defaults?.synchronize()
  }

  static func setApnsToken(_ token: String?, environment: String?) {
    setOrRemove(token, forKey: apnsTokenKey)
    setOrRemove(environment, forKey: apnsEnvironmentKey)
    defaults?.synchronize()
  }

  static func apnsTokenInfo() -> (token: String, environment: String)? {
    guard let token = clean(defaults?.string(forKey: apnsTokenKey)),
          let environment = clean(defaults?.string(forKey: apnsEnvironmentKey)) else {
      return nil
    }
    return (token, environment)
  }

  static func enqueueNotificationRoute(
    userInfo: [AnyHashable: Any],
    action: String? = nil
  ) {
    let payload = NotificationRoutePayload(
      payloadId: clean(userInfo["payloadId"] as? String),
      transactionId: clean(userInfo["transactionId"] as? String),
      smartInboxItemId: clean(userInfo["smartInboxItemId"] as? String),
      notificationType: clean(userInfo["notificationType"] as? String),
      source: clean(userInfo["source"] as? String),
      receivedAt: isoFormatter.string(from: Date()),
      notificationLogId: clean(userInfo["notificationLogId"] as? String),
      action: clean(action)
    )
    guard payload.payloadId != nil ||
      payload.transactionId != nil ||
      payload.smartInboxItemId != nil else {
      return
    }
    // MALI-068n: read-modify-write under the shared cross-process lock so a
    // concurrent host/extension write cannot lose a route.
    _ = try? withQueueLock {
      var queue = loadNotificationRoutes()
      queue.append(payload)
      if queue.count > 10 {
        queue.removeFirst(queue.count - 10)
      }
      if let data = try? JSONEncoder().encode(queue) {
        defaults?.set(data, forKey: pendingNotificationRoutesKey)
        defaults?.synchronize()
      }
    }
  }

  static func consumePendingNotificationRoutesJSON() -> String? {
    try? withQueueLock { () throws -> String? in
      let queue = loadNotificationRoutes()
      guard !queue.isEmpty,
            let data = try? JSONEncoder().encode(queue),
            let json = String(data: data, encoding: .utf8) else {
        return nil
      }
      defaults?.removeObject(forKey: pendingNotificationRoutesKey)
      defaults?.synchronize()
      return json
    }
  }

  static func isoString(from date: Date) -> String {
    isoFormatter.string(from: date)
  }

  /// Queues one notification lifecycle event. Capped at 200 entries (oldest
  /// dropped first) so a host app that never opens cannot grow this
  /// unboundedly — losing the oldest diagnostic events is an acceptable
  /// trade-off; losing the ability to record new ones is not.
  static func enqueueNotificationLogEvent(
    notificationLogId: String,
    eventType: String,
    channel: String,
    notificationType: String,
    relatedEntityType: String? = nil,
    relatedEntityId: String? = nil,
    errorCode: String? = nil,
    errorReason: String? = nil
  ) {
    let payload = NotificationLogEventPayload(
      notificationLogId: notificationLogId,
      eventType: eventType,
      channel: channel,
      notificationType: notificationType,
      relatedEntityType: clean(relatedEntityType),
      relatedEntityId: clean(relatedEntityId),
      errorCode: clean(errorCode),
      errorReason: clean(errorReason).map { String($0.prefix(300)) },
      occurredAt: isoFormatter.string(from: Date())
    )
    // MALI-068n: RMW under the shared cross-process lock.
    _ = try? withQueueLock {
      var queue = loadNotificationLogEvents()
      queue.append(payload)
      if queue.count > 200 {
        queue.removeFirst(queue.count - 200)
      }
      guard let data = try? JSONEncoder().encode(queue) else { return }
      defaults?.set(data, forKey: notificationLogEventsKey)
      defaults?.synchronize()
    }
  }

  static func consumePendingNotificationLogEventsJSON() -> String? {
    try? withQueueLock { () throws -> String? in
      let queue = loadNotificationLogEvents()
      guard !queue.isEmpty,
            let data = try? JSONEncoder().encode(queue),
            let json = String(data: data, encoding: .utf8) else {
        return nil
      }
      defaults?.removeObject(forKey: notificationLogEventsKey)
      defaults?.synchronize()
      return json
    }
  }

  private static func loadNotificationLogEvents() -> [NotificationLogEventPayload] {
    guard let data = defaults?.data(forKey: notificationLogEventsKey),
          let queue = try? JSONDecoder().decode([NotificationLogEventPayload].self, from: data) else {
      return []
    }
    return queue
  }

  /// Signals the host Flutter app that backend relay state may have changed.
  ///
  /// Backend-first captures do not need to store the raw SMS in App Group on
  /// success; the relay row is already in `processed_captures`. This notification
  /// wakes the host app, when running, so Flutter can call `sync-captures` and
  /// refresh Drift/UI without waiting for a notification tap.
  static func notifyPendingCaptureUpdateAvailable() {
    notifyPendingMessagesAvailable()
  }

  private static func loadQueue() throws -> [Payload] {
    guard let data = defaults?.data(forKey: queueKey) else { return [] }
    // MALI-031: the blob is AES-GCM encrypted. A legacy plaintext-JSON blob is
    // migrated transparently. CAP-0: a blob that cannot be read THROWS — it is
    // never reported as an empty queue, because the next enqueue would then
    // overwrite recoverable records. It is deliberately NOT deleted here.
    return try decodeQueueBlob(data)
  }

  private static func loadNotificationRoutes() -> [NotificationRoutePayload] {
    guard let data = defaults?.data(forKey: pendingNotificationRoutesKey),
          let queue = try? JSONDecoder().decode([NotificationRoutePayload].self, from: data) else {
      return []
    }
    return queue
  }

  /// MALI-054n / MALI-031: removes ALL user-owned capture residue from the App
  /// Group AND invalidates the device secret + queue-encryption key, so a
  /// previous account's bank messages can never surface under a new identity and
  /// user B never inherits user A's device auth or a key that could decrypt
  /// residual data. Runs under the queue lock (same discipline as the queue
  /// writers). Install-level NON-secret config (backend URL/keys, install id,
  /// APNs token) is preserved and re-managed by setBackendConfig; the device
  /// secret is re-provisioned on the next login. Returns true on completion,
  /// false (nothing purged) when the queue lock could not be taken.
  @discardableResult
  static func purgeUserOwnedState() -> Bool {
    do {
      try withQueueLock {
        defaults?.removeObject(forKey: queueKey)
        defaults?.removeObject(forKey: legacyKey)
        defaults?.removeObject(forKey: pendingCountKey)
        defaults?.removeObject(forKey: latestPayloadIDKey)
        defaults?.removeObject(forKey: pendingNotificationRoutesKey)
        defaults?.removeObject(forKey: notificationLogEventsKey)
        defaults?.removeObject(forKey: deviceSecretKey) // legacy plaintext, if any
        SharedKeychain.remove(forKey: deviceSecretKC)
        SharedKeychain.remove(forKey: queueEncryptionKeyKC)
        defaults?.synchronize()
      }
    } catch {
      return false
    }
    return true
  }

  /// CAP-0: the body NEVER runs without the exclusive lock. If the container,
  /// the lock file or the flock itself is unavailable this throws instead.
  private static func withQueueLock<T>(_ body: () throws -> T) throws -> T {
    guard !lockUnavailableOverride,
          let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
          ) else {
      throw QueueError.lockUnavailable
    }
    let lockURL = containerURL.appendingPathComponent(queueLockFileName)
    let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard fd >= 0 else {
      throw QueueError.lockUnavailable
    }
    defer { close(fd) }
    while flock(fd, LOCK_EX) != 0 {
      guard errno == EINTR else { throw QueueError.lockUnavailable }
    }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }

  private static func saveQueue(_ queue: [Payload], notifyHost: Bool = true) throws {
    if queue.isEmpty {
      defaults?.removeObject(forKey: queueKey)
    } else {
      let data = try encodeQueueBlob(queue)
      defaults?.set(data, forKey: queueKey)
    }
    updatePendingMetadata(queue)
    defaults?.synchronize()
    if notifyHost && !queue.isEmpty {
      notifyPendingMessagesAvailable()
    }
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

  private static func setOrRemove(_ value: String?, forKey key: String) {
    if let cleanValue = clean(value) {
      defaults?.set(cleanValue, forKey: key)
    } else {
      defaults?.removeObject(forKey: key)
    }
  }

  static func makePayloadID(
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

  // MARK: - Capture-queue encryption (MALI-031)

  private static func readQueueKey() -> (status: OSStatus, data: Data?) {
    queueKeyReadOverride?() ?? SharedKeychain.read(forKey: queueEncryptionKeyKC)
  }

  /// The AES-256 key that encrypts the capture queue at rest, held in the shared
  /// Keychain (accessible to the host app and the extension). Generated once,
  /// and ONLY when the Keychain positively reports `errSecItemNotFound`: any
  /// other status (e.g. `errSecInteractionNotAllowed` before first unlock) throws,
  /// because replacing a key that merely could not be read would make the
  /// existing encrypted queue permanently undecryptable (CAP-0).
  private static func encryptionKey() throws -> SymmetricKey {
    let read = readQueueKey()
    switch read.status {
    case errSecSuccess:
      guard let data = read.data, data.count == 32 else {
        throw QueueError.keyUnavailable(errSecDecode)
      }
      return SymmetricKey(data: data)
    case errSecItemNotFound:
      let key = SymmetricKey(size: .bits256)
      let raw = key.withUnsafeBytes { Data(Array($0)) }
      let status = SharedKeychain.writeData(raw, forKey: queueEncryptionKeyKC)
      guard status == errSecSuccess else { throw QueueError.keyUnavailable(status) }
      return key
    default:
      throw QueueError.keyUnavailable(read.status)
    }
  }

  /// Encrypts the queue as an AES-GCM combined blob. Throws if the shared
  /// Keychain (hence the key) is unavailable, so the caller does NOT overwrite a
  /// good blob with an unencrypted one.
  private static func encodeQueueBlob(_ queue: [Payload]) throws -> Data {
    let key = try encryptionKey()
    guard let json = try? JSONEncoder().encode(queue),
          let sealed = try? AES.GCM.seal(json, using: key).combined else {
      throw QueueError.encodingFailed
    }
    return sealed
  }

  /// Decrypts a stored blob. New blobs are AES-GCM sealed; a legacy plaintext
  /// JSON blob is decoded transparently (one-time migration on next save). This
  /// path only READS the key and never creates one: an unreadable key throws
  /// `keyUnavailable`, and a blob that decrypts under no key (corrupt, or the
  /// key is gone) throws `unreadable` — callers must not treat either as empty.
  private static func decodeQueueBlob(_ data: Data) throws -> [Payload] {
    let read = readQueueKey()
    guard read.status == errSecSuccess || read.status == errSecItemNotFound else {
      throw QueueError.keyUnavailable(read.status)
    }
    if let keyData = read.data, keyData.count == 32,
       let box = try? AES.GCM.SealedBox(combined: data),
       let plain = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)),
       let queue = try? JSONDecoder().decode([Payload].self, from: plain) {
      return queue
    }
    // Legacy plaintext migration path.
    if let queue = try? JSONDecoder().decode([Payload].self, from: data) {
      return queue
    }
    throw QueueError.unreadable
  }
}

/// MALI-031 — secret material (device secret, capture-queue key) lives here, in
/// a shared Keychain access group readable by the host app and the Share
/// Extension, never in App Group UserDefaults. The access group's team prefix is
/// resolved at build time from the `AppIdentifierPrefix` Info.plist value; the
/// `.shared` group is declared in each target's `keychain-access-groups`
/// entitlement. Items are `ThisDeviceOnly` and never sync to iCloud.
private enum SharedKeychain {
  private static let service = "com.youssefsafwat.mali.sharedcapture"

  /// The shared access group, or nil when the team prefix can't be resolved
  /// (e.g. an unsigned simulator/dev build). When nil, the item is stored in the
  /// app's DEFAULT keychain instead — still Keychain (ThisDeviceOnly), never
  /// UserDefaults — so the app stays functional; cross-process app↔extension
  /// sharing then requires the entitled group and is a device-verified path.
  static var accessGroup: String? {
    guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
          !prefix.isEmpty else {
      return nil
    }
    return "\(prefix)com.youssefsafwat.mali.shared"
  }

  private static func baseQuery(_ key: String) -> [String: Any] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    if let group = accessGroup {
      q[kSecAttrAccessGroup as String] = group
    }
    return q
  }

  /// Updates the item in place and adds it only when it does not exist yet.
  /// Never delete-then-add: a failure between the two calls would destroy the
  /// only copy of the key (CAP-0).
  @discardableResult
  static func writeData(_ data: Data, forKey key: String) -> OSStatus {
    let base = baseQuery(key)
    let status = SecItemUpdate(
      base as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    guard status == errSecItemNotFound else { return status }
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(add as CFDictionary, nil)
  }

  @discardableResult
  static func setData(_ data: Data, forKey key: String) -> Bool {
    writeData(data, forKey: key) == errSecSuccess
  }

  /// The raw Keychain status is kept so callers can tell "not there"
  /// (`errSecItemNotFound`) from "could not be read right now".
  static func read(forKey key: String) -> (status: OSStatus, data: Data?) {
    var query = baseQuery(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status, status == errSecSuccess ? result as? Data : nil)
  }

  static func data(forKey key: String) -> Data? {
    read(forKey: key).data
  }

  @discardableResult
  static func setString(_ value: String, forKey key: String) -> Bool {
    setData(Data(value.utf8), forKey: key)
  }

  static func string(forKey key: String) -> String? {
    guard let data = data(forKey: key) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func remove(forKey key: String) {
    SecItemDelete(baseQuery(key) as CFDictionary)
  }
}
