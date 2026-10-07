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

  // Queue v3 (CAP-6) is an encrypted file in the App Group container. The v2
  // UserDefaults blob is read ONLY to migrate it (§4.7) and is deliberately kept
  // afterwards: the 7-day P2 rollback grace needs it (manifest §13).
  private static let queueKey = "pending_bank_messages_v2"
  private static let queueFileName = "pending_bank_messages_v3.bin"
  private static let barrierFileName = "capture_destructive_barrier_v1.json"
  private static let migratedKey = "pending_bank_messages_v3_migrated"
  private static let ownerGenerationKey = "capture_owner_generation_v1"
  // A-12-min R4: bumped by every owner clear (sign-out, transition, removal), so
  // a publish that started before the clear can never land after it.
  private static let ownerEpochKey = "capture_owner_epoch_v1"
  private static let consentMirrorKey = "capture_consent_mirror_v1"
  private static let contractV2Key = "capture_contract_v2"
  private static let notifyV2Key = "capture_notify_v2"
  private static let expiredUnboundCountKey = "capture_unbound_expired_count_v1"
  private static let expiredUnboundLastKey = "capture_unbound_expired_last_v1"
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
  // CAP-6 (§4.2): the active owner record and the last-admitted hint live in the
  // shared Keychain; `uidHmacKeyKC` keys the uidHash (HMAC-SHA256) so a hash is
  // meaningless off this device.
  private static let activeOwnerKC = "active_capture_owner_v1"
  private static let lastAdmittedHashKC = "last_admitted_uid_hash_v1"
  private static let uidHmacKeyKC = "capture_uid_hmac_key_v1"

  // §4.5 queue quotas. These are the shipping values; changing any of them
  // needs explicit approval (manifest §14.10).
  static let ownerMaxItems = 500
  static let ownerMaxBytes = 2 * 1024 * 1024
  static let unboundMaxItems = 200
  static let unboundMaxBytes = 512 * 1024
  static let deviceMaxBytes = 8 * 1024 * 1024
  /// Unbound items expire after this long (§4.5). Stamped items never expire by age.
  static let unboundExpiryDays = 30

  static let ownerStateStamped = "stamped"
  static let ownerStateUnbound = "unbound"
  static let originLegacyV2 = "legacy_v2"
  static let reviewSuspectedAlreadyImported = "suspected_already_imported"

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
    /// The queue file could not be written or removed.
    case storageWriteFailed
    /// §4.5: a count or byte quota is exhausted. Nothing is ever evicted.
    case quotaExceeded
    /// §4.4: a Remove-data barrier is in force; the capture is refused visibly.
    case barrierActive
    /// The owner record is not the owner the caller required (stamp race).
    case ownerChanged
  }

  /// Test seams (CAP-0), never set in production: the Keychain read of the
  /// queue key, and a forced lock failure.
  static var queueKeyReadOverride: (() -> (status: OSStatus, data: Data?))?
  static var lockUnavailableOverride = false
  /// CAP-6 test seams: the owner-record Keychain read, and a hook invoked while
  /// the queue flock is held during stamping (lets a test prove the lock).
  static var ownerRecordReadOverride: (() -> (status: OSStatus, data: Data?))?
  static var stampingHook: (() -> Void)?
  /// CAP-6 test seam for the 30-day unbound expiry.
  static var clockOverride: (() -> Date)?

  struct BackendConfig {
    let cloudProcessingEnabled: Bool
    let installID: String?
    let deviceSecret: String?
    let backendURL: String?
    let anonKey: String?
    /// Mirror of the server capability `capture_contract_v2`, set by Dart.
    /// Default false: uploads stay on the legacy contract.
    var captureContractV2: Bool = false
    /// Mirror of the client flag `capture_notify_v2` (CAP-7), set by Dart.
    /// Default false: the App Intent banners behave exactly as before.
    var captureNotifyV2: Bool = false

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
    /// CAP-6 refusals. They reuse the approved storage copy below: NEW
    /// user-visible copy needs approval (see the CAP-6a report for proposals).
    case quotaFull
    case removalInProgress
    case ownerChanged

    /// Method-channel error code for a refused re-enqueue.
    var bridgeCode: String {
      switch self {
      case .quotaFull: return "quota_exceeded"
      case .removalInProgress: return "removal_in_progress"
      case .ownerChanged: return "owner_changed"
      default: return "reenqueue_failed"
      }
    }

    /// User-facing copy (approved, R9). Arabic when the device's preferred
    /// language is Arabic, English otherwise. Never carries technical text.
    var userMessage: String {
      let arabic = Locale.preferredLanguages.first?.lowercased().hasPrefix("ar") == true
      switch self {
      case .emptyText:
        return arabic
          ? "لم يصل نص رسالة البنك إلى قِرش. تأكد أن الاختصار يمرّر نص الرسالة، ثم حاول مرة أخرى."
          : "Qirsh didn't receive the bank message text. Make sure the Shortcut passes the message text, then try again."
      case .storageUnavailable, .quotaFull, .removalInProgress, .ownerChanged:
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
    var status: String?
    var failureReason: String?
    var sentAt: String?
    let createdAt: String?
    /// True when the App Intent's Date Received parameter was missing and the
    /// receive time was inferred (R9). Optional so older builds still decode.
    let receivedAtInferred: Bool?

    // Queue v3 ownership fields (§4.2). All optional so a v2-shaped record
    // still decodes; Flutter ignores keys it does not know.
    /// `stamped` (bound to `ownerUid`) or `unbound`.
    var ownerState: String? = nil
    var ownerUid: String? = nil
    /// The owner-record generation this item was stamped under.
    var ownerGeneration: Int? = nil
    /// Unbound only: the last admitted uidHash (HMAC). A hint is never authority.
    var ownerHint: String? = nil
    /// When the item became unbound (the 30-day expiry runs from here).
    var unboundAt: String? = nil
    /// Non-financial annotation (`suspected_already_imported`), review only.
    var reviewState: String? = nil
    /// `legacy_v2` for items migrated from the v2 queue.
    var origin: String? = nil
    /// Bound by an explicit claim: never uploaded, never AI (§4.3).
    var localOnly: Bool? = nil
    /// Remove-data barrier tag (§4.4); swept with its barrier.
    var barrierNonce: String? = nil
  }

  /// §4.2 active owner record, held in the shared Keychain.
  struct OwnerRecord: Codable, Equatable {
    let uid: String
    let uidHash: String
    let generation: Int
  }

  /// §4.4 destructive barrier, persisted so a crashed removal resumes.
  struct RemovalBarrier: Codable, Equatable {
    let nonce: String
    let uidHash: String
    let startedAt: String
  }

  /// What the App Intent may do with a persisted capture (§4.2 pre-upload re-check).
  enum UploadDecision: Equatable {
    /// Upload as `ownerUid`. `allowAi` is the owner's consent mirror. A missing
    /// mirror is never `allowed` (A-12-min R2): there is no install-level fallback.
    case allowed(ownerUid: String, allowAi: Bool)
    /// Zero egress, zero AI; the capture stays on the device for a local parse.
    case localOnly
    /// Not this owner's to process now: no egress and no banner.
    case waiting
  }

  enum ClaimOutcome: Equatable {
    /// Number of items bound (claim) or deleted (discard).
    case applied(Int)
    /// Items changed since the prompt snapshot; NOTHING was mutated.
    case stale
    /// uid / owner record / generation / replica / session do not all agree;
    /// NOTHING was mutated.
    case ownerMismatch
  }

  struct UnboundSummary: Equatable {
    let ids: [String]
    let senders: [String]
    var count: Int { ids.count }
  }

  /// Adds a captured bank message to the shared queue.
  ///
  /// Duplicate prevention is scoped to pending native payloads only. Transaction
  /// duplicate detection remains in Flutter where the domain model lives.
  ///
  /// [notifyHost] is false only for Flutter's own re-enqueue of a message whose
  /// processing failed: posting the Darwin notification there would wake the
  /// host again immediately and loop drain → fail → re-enqueue → drain forever.
  ///
  /// CAP-6 (§4.2): the owner record is read, the item stamped, the quotas checked
  /// and the item persisted in ONE critical section under the queue flock. With
  /// no admitted owner the item is `unbound` (with the last-admitted hint unless
  /// cleared); with a Remove-data barrier in force nothing is persisted.
  /// [requireOwnerUid] (a re-enqueue) refuses when the active owner is not that uid.
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
    notifyHost: Bool = true,
    requireOwnerUid: String? = nil,
    localOnly: Bool? = nil
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
        stampingHook?()
        guard try readBarrier() == nil else { throw QueueError.barrierActive }
        var queue = try loadQueuePruned()
        if let existing = queue.first(where: { $0.id == payloadID }) {
          if notifyHost {
            notifyPendingMessagesAvailable()
          }
          return .duplicate(existing)
        }

        var stamped = payload
        let owner = try readActiveOwner()
        if let required = requireOwnerUid, normalizedUID(required) != owner?.uid {
          throw QueueError.ownerChanged
        }
        stamped.localOnly = localOnly
        if let owner = owner {
          stamped.ownerState = ownerStateStamped
          stamped.ownerUid = owner.uid
          stamped.ownerGeneration = owner.generation
          // A-12-min R3: consent is judged at capture time. A missing mirror or
          // `cloud == false` makes the item local-only for good: it never uploads
          // and never reaches AI, even if Cloud is turned ON later. A replay-able
          // `pendingSend` becomes `sent`, so no drain replays it.
          if consentMirror(forHash: owner.uidHash)?.cloud != true {
            stamped.localOnly = true
            if stamped.status == CaptureStatus.pendingSend.rawValue {
              stamped.status = CaptureStatus.sent.rawValue
            }
          }
        } else {
          stamped.ownerState = ownerStateUnbound
          stamped.ownerHint = try readLastAdmittedHash()
          stamped.unboundAt = createdAtString
        }
        try checkQuotas(queue, adding: stamped)
        queue.append(stamped)
        try saveQueue(queue, notifyHost: notifyHost)
        return .enqueued(stamped)
      }
    } catch {
      var kind = FailureKind.storageUnavailable
      if case let QueueError.keyUnavailable(status) = error,
         status == errSecInteractionNotAllowed {
        kind = .deviceLocked
      }
      if case QueueError.quotaExceeded = error { kind = .quotaFull }
      if case QueueError.barrierActive = error { kind = .removalInProgress }
      if case QueueError.ownerChanged = error { kind = .ownerChanged }
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
      var item = queue[index]
      item.status = status.rawValue
      item.failureReason = clean(failureReason)
      if status == .sent { item.sentAt = isoFormatter.string(from: Date()) }
      queue[index] = item
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
  /// Only the ACTIVE owner's stamped items count: unbound items and items that
  /// wait for another owner are not importable now (§4.2). Runs under the lock
  /// because loading may migrate the v2 queue.
  static func hasPendingMessages() -> Bool {
    (try? withQueueLock { () throws -> Bool in
      let queue = try loadQueue()
      if !importableItems(queue, owner: try readActiveOwner()).isEmpty { return true }
      return defaults?.string(forKey: legacyKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty == false
    }) ?? false
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
      var queue = try loadQueuePruned()
      if foldLegacyText(into: &queue) {
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
      let mine = importableItems(queue, owner: try readActiveOwner())
      guard !mine.isEmpty,
            let data = try? JSONEncoder().encode(mine),
            let json = String(data: data, encoding: .utf8) else {
        return nil
      }
      return json
    }
  }

  /// Drains the ACTIVE owner's items (a legacy value is folded in as unbound and
  /// so not returned) and returns a JSON array. Items stamped to another owner
  /// and unbound items stay queued.
  ///
  /// The items are removed only after JSON encoding succeeds so messages are not
  /// lost if encoding fails.
  static func consumePendingPayloadsJSON() throws -> String? {
    try withQueueLock {
      var queue = try loadQueuePruned()
      let folded = foldLegacyText(into: &queue)
      let owner = try readActiveOwner()
      let mine = importableItems(queue, owner: owner)
      guard !mine.isEmpty,
            let data = try? JSONEncoder().encode(mine),
            let json = String(data: data, encoding: .utf8) else {
        if folded {
          try saveQueue(queue, notifyHost: false)
          defaults?.removeObject(forKey: legacyKey)
          defaults?.synchronize()
        }
        updatePendingMetadata(queue)
        return nil
      }
      let mineIDs = Set(mine.compactMap { $0.id })
      queue.removeAll(where: { mineIDs.contains($0.id ?? "") })
      try saveQueue(queue, notifyHost: false)
      defaults?.removeObject(forKey: legacyKey)
      defaults?.synchronize()
      return json
    }
  }

  /// Backward-compatible single consume that returns the oldest text only.
  static func consumePendingText() throws -> String? {
    try withQueueLock {
      var queue = try loadQueuePruned()
      let owner = try readActiveOwner()
      guard let first = importableItems(queue, owner: owner).first else {
        if let legacy = defaults?.string(forKey: legacyKey),
           !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          defaults?.removeObject(forKey: legacyKey)
          updatePendingMetadata(queue)
          defaults?.synchronize()
          return legacy
        }
        updatePendingMetadata(queue)
        return nil
      }
      queue.removeAll(where: { $0.id == first.id })
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
      anonKey: clean(defaults?.string(forKey: anonKeyKey)),
      captureContractV2: defaults?.bool(forKey: contractV2Key) ?? false,
      captureNotifyV2: defaults?.bool(forKey: notifyV2Key) ?? false
    )
  }

  /// CAP-7: mirrors the `capture_notify_v2` flag for the App Intent.
  static func setCaptureNotifyV2(_ enabled: Bool) {
    defaults?.set(enabled, forKey: notifyV2Key)
    defaults?.synchronize()
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
    aiConsentGranted: Bool,
    captureContractV2: Bool = false
  ) {
    defaults?.set(cloudProcessingEnabled, forKey: cloudProcessingEnabledKey)
    defaults?.set(captureContractV2, forKey: contractV2Key)
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
    // MALI-031: the file holds an AES-GCM encrypted blob. CAP-0: a blob that
    // cannot be read THROWS — it is never reported as an empty queue, because
    // the next enqueue would then overwrite recoverable records. It is
    // deliberately NOT deleted here. Callers hold the queue lock.
    if let data = try readQueueFile() { return try decodeQueueBlob(data) }
    return try migrateLegacyQueue()
  }

  /// `loadQueue` plus the §4.5 expiry: unbound items older than
  /// `unboundExpiryDays` are removed (stamped items never expire by age) and a
  /// content-free diagnostics counter is bumped. Callers hold the queue lock.
  private static func loadQueuePruned(now: Date = clockOverride?() ?? Date()) throws -> [Payload] {
    var queue = try loadQueue()
    let cutoff = now.addingTimeInterval(-Double(unboundExpiryDays) * 86_400)
    let before = queue.count
    queue.removeAll(where: { item in
      guard item.ownerState == ownerStateUnbound,
            let since = (item.unboundAt ?? item.createdAt).flatMap(isoFormatter.date(from:))
      else { return false }
      return since < cutoff
    })
    let expired = before - queue.count
    if expired > 0 {
      try saveQueue(queue, notifyHost: false)
      defaults?.set(
        (defaults?.integer(forKey: expiredUnboundCountKey) ?? 0) + expired,
        forKey: expiredUnboundCountKey
      )
      defaults?.set(isoFormatter.string(from: now), forKey: expiredUnboundLastKey)
    }
    return queue
  }

  /// §4.7: the v2 queue becomes v3 ONCE. Nothing is imported or dropped here.
  /// Native cannot see the adopted replica, so every v2 item is quarantined as
  /// `unbound` with NO hint (the legacy owner marker is never trusted); Dart
  /// removes the ones its adopted replica proves consumed (receipt or
  /// tx.id == capture_id) through `resolveLegacyItems`. Quotas do not apply: a
  /// legacy item is never evicted. The v2 blob stays for the rollback grace.
  private static func migrateLegacyQueue() throws -> [Payload] {
    guard defaults?.bool(forKey: migratedKey) != true else { return [] }
    guard let blob = defaults?.data(forKey: queueKey) else {
      defaults?.set(true, forKey: migratedKey)
      return []
    }
    let now = isoFormatter.string(from: Date())
    let items = try decodeQueueBlob(blob).map { quarantinedLegacy($0, at: now) }
    if !items.isEmpty { try saveQueue(items, notifyHost: false) }
    defaults?.set(true, forKey: migratedKey)
    return items
  }

  private static func quarantinedLegacy(_ item: Payload, at now: String) -> Payload {
    var item = item
    item.ownerState = ownerStateUnbound
    item.ownerUid = nil
    item.ownerGeneration = nil
    item.ownerHint = nil
    item.unboundAt = now
    item.origin = originLegacyV2
    return item
  }

  /// A pre-queue single-text value becomes a quarantined queue item.
  private static func foldLegacyText(into queue: inout [Payload]) -> Bool {
    guard let legacy = defaults?.string(forKey: legacyKey),
          !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    let receivedAt = isoFormatter.string(from: Date())
    queue.append(quarantinedLegacy(Payload(
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
    ), at: receivedAt))
    return true
  }

  /// §4.2 consumption rule: only items stamped to the ACTIVE owner are importable.
  /// Unbound items and items stamped to another owner wait, invisible.
  private static func importableItems(_ queue: [Payload], owner: OwnerRecord?) -> [Payload] {
    guard let owner = owner else { return [] }
    return queue.filter { $0.ownerState == ownerStateStamped && $0.ownerUid == owner.uid }
  }

  private static func queueFileURL() throws -> URL {
    try appGroupContainerURL().appendingPathComponent(queueFileName)
  }

  private static func appGroupContainerURL() throws -> URL {
    guard let url = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    ) else {
      throw QueueError.lockUnavailable
    }
    return url
  }

  /// nil only when the file does not exist; an existing file that cannot be read
  /// throws (never "empty").
  private static func readQueueFile() throws -> Data? {
    let url = try queueFileURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url) else { throw QueueError.unreadable }
    return data
  }

  /// §4.5 quotas over the queue AS IT WOULD BE after [item] is added; throws
  /// before anything is written, and never evicts. Scope: the item's stamped
  /// owner, or all unbound items, plus the device-wide byte cap.
  private static func checkQuotas(_ queue: [Payload], adding item: Payload) throws {
    func size(_ value: Payload) throws -> Int {
      guard let data = try? JSONEncoder().encode(value) else { throw QueueError.encodingFailed }
      return data.count
    }
    let stamped = item.ownerState == ownerStateStamped
    let scope = queue.filter {
      stamped
        ? ($0.ownerState == ownerStateStamped && $0.ownerUid == item.ownerUid)
        : ($0.ownerState == ownerStateUnbound)
    }
    var scopeBytes = 0
    for value in scope { scopeBytes += try size(value) }
    var deviceBytes = 0
    for value in queue { deviceBytes += try size(value) }
    let itemBytes = try size(item)
    let maxItems = stamped ? ownerMaxItems : unboundMaxItems
    let maxBytes = stamped ? ownerMaxBytes : unboundMaxBytes
    if scope.count + 1 > maxItems
      || scopeBytes + itemBytes > maxBytes
      || deviceBytes + itemBytes > deviceMaxBytes {
      throw QueueError.quotaExceeded
    }
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
        try removeQueueFile()
        defaults?.removeObject(forKey: queueKey)
        defaults?.removeObject(forKey: migratedKey)
        defaults?.removeObject(forKey: legacyKey)
        defaults?.removeObject(forKey: pendingCountKey)
        defaults?.removeObject(forKey: latestPayloadIDKey)
        defaults?.removeObject(forKey: pendingNotificationRoutesKey)
        defaults?.removeObject(forKey: notificationLogEventsKey)
        defaults?.removeObject(forKey: deviceSecretKey) // legacy plaintext, if any
        SharedKeychain.remove(forKey: deviceSecretKC)
        SharedKeychain.remove(forKey: queueEncryptionKeyKC)
        // A full wipe also forgets the owner and the hint. The Remove-data
        // barrier is deliberately NOT cleared here; only its final sweep does.
        SharedKeychain.remove(forKey: activeOwnerKC)
        SharedKeychain.remove(forKey: lastAdmittedHashKC)
        bumpOwnerEpoch()
        defaults?.removeObject(forKey: consentMirrorKey)
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
      try removeQueueFile()
    } else {
      let data = try encodeQueueBlob(queue)
      // Temp file + rename (`.atomic`), readable after the first unlock.
      do {
        try data.write(
          to: try queueFileURL(),
          options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
      } catch let error as QueueError {
        throw error
      } catch {
        throw QueueError.storageWriteFailed
      }
    }
    updatePendingMetadata(queue)
    defaults?.synchronize()
    if notifyHost && !queue.isEmpty {
      notifyPendingMessagesAvailable()
    }
  }

  private static func removeQueueFile() throws {
    let url = try queueFileURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      throw QueueError.storageWriteFailed
    }
  }

  // MARK: - Owner record, hint, barrier (CAP-6, §4.2 / §4.4)
  //
  // Every function below that writes takes the queue flock, so the owner record
  // can never change underneath an intent that is stamping or authorizing an
  // upload. Reads that must agree with the queue also run under it.

  static func normalizedUID(_ uid: String) -> String {
    uid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func readActiveOwner() throws -> OwnerRecord? {
    let read = ownerRecordReadOverride?() ?? SharedKeychain.read(forKey: activeOwnerKC)
    switch read.status {
    case errSecSuccess:
      guard let data = read.data,
            let record = try? JSONDecoder().decode(OwnerRecord.self, from: data) else {
        throw QueueError.keyUnavailable(errSecDecode)
      }
      return record
    case errSecItemNotFound:
      return nil
    default:
      // Before first unlock / Keychain unavailable: the capture is NOT persisted.
      throw QueueError.keyUnavailable(read.status)
    }
  }

  private static func readLastAdmittedHash() throws -> String? {
    let read = SharedKeychain.read(forKey: lastAdmittedHashKC)
    switch read.status {
    case errSecSuccess:
      return read.data.flatMap { String(data: $0, encoding: .utf8) }
    case errSecItemNotFound:
      return nil
    default:
      throw QueueError.keyUnavailable(read.status)
    }
  }

  private static func writeKeychain(_ data: Data, forKey key: String) throws {
    let status = SharedKeychain.writeData(data, forKey: key)
    guard status == errSecSuccess else { throw QueueError.keyUnavailable(status) }
  }

  private static func removeKeychain(forKey key: String) throws {
    let status = SharedKeychain.remove(forKey: key)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw QueueError.keyUnavailable(status)
    }
  }

  /// HMAC-SHA256 key for uidHash, created ONLY on errSecItemNotFound (the same
  /// discipline as the queue key) and always under the queue flock.
  private static func uidHmacKey() throws -> SymmetricKey {
    let read = SharedKeychain.read(forKey: uidHmacKeyKC)
    switch read.status {
    case errSecSuccess:
      guard let data = read.data, data.count == 32 else {
        throw QueueError.keyUnavailable(errSecDecode)
      }
      return SymmetricKey(data: data)
    case errSecItemNotFound:
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw QueueError.keyUnavailable(errSecAllocate)
      }
      let raw = Data(bytes)
      try writeKeychain(raw, forKey: uidHmacKeyKC)
      return SymmetricKey(data: raw)
    default:
      throw QueueError.keyUnavailable(read.status)
    }
  }

  private static func uidHash(_ uid: String) throws -> String {
    let mac = HMAC<SHA256>.authenticationCode(
      for: Data(normalizedUID(uid).utf8),
      using: try uidHmacKey()
    )
    return Data(mac).map { String(format: "%02x", $0) }.joined()
  }

  /// The active owner record, or nil when no user is admitted.
  static func activeOwner() throws -> OwnerRecord? {
    try withQueueLock { try readActiveOwner() }
  }

  /// The owner epoch: bumped by every owner clear (A-12-min R4). Dart reads it
  /// BEFORE a publish and passes it back, so a publish that began before a
  /// sign-out / transition / removal clear cannot land after it.
  static func ownerEpoch() throws -> Int {
    try withQueueLock { defaults?.integer(forKey: ownerEpochKey) ?? 0 }
  }

  private static func bumpOwnerEpoch() {
    defaults?.set((defaults?.integer(forKey: ownerEpochKey) ?? 0) + 1, forKey: ownerEpochKey)
  }

  /// The consent a publish writes together with the owner (A-12-min R4).
  struct ConsentMirrorValue: Equatable {
    let cloud: Bool
    let ai: Bool
    let version: Int
  }

  /// Publishes `{uid, uidHash, generation}` as the active owner, writing the
  /// owner's consent mirror FIRST and the owner record second, in ONE flock
  /// (A-12-min R4): an owner is never visible without its mirror. It compares
  /// and swaps on [expectedEpoch] (`ownerChanged` when a clear happened since
  /// Dart read it) and is refused while a Remove-data barrier is in force. The
  /// caller decides whether a network link was required first: Cloud OFF
  /// publishes locally; Cloud ON only after `link_capture_device(consent)`
  /// succeeded (§4.2). Re-publishing the current owner rewrites the mirror and
  /// keeps the generation.
  @discardableResult
  static func publishActiveOwner(
    uid: String,
    mirror: ConsentMirrorValue,
    expectedEpoch: Int
  ) throws -> OwnerRecord {
    try withQueueLock {
      guard try readBarrier() == nil else { throw QueueError.barrierActive }
      guard (defaults?.integer(forKey: ownerEpochKey) ?? 0) == expectedEpoch else {
        throw QueueError.ownerChanged
      }
      let normalized = normalizedUID(uid)
      guard !normalized.isEmpty else { throw QueueError.ownerChanged }
      let hash = try uidHash(normalized)
      writeConsentMirrorEntry(hash: hash, mirror: mirror)
      if let current = try readActiveOwner(), current.uid == normalized { return current }
      let generation = (defaults?.integer(forKey: ownerGenerationKey) ?? 0) + 1
      let record = OwnerRecord(uid: normalized, uidHash: hash, generation: generation)
      guard let data = try? JSONEncoder().encode(record) else { throw QueueError.encodingFailed }
      try writeKeychain(data, forKey: activeOwnerKC)
      try writeKeychain(Data(hash.utf8), forKey: lastAdmittedHashKC)
      defaults?.set(generation, forKey: ownerGenerationKey)
      defaults?.synchronize()
      return record
    }
  }

  /// Clears the owner record (sign-out, or the start of an account transition).
  /// [clearHint] true at a transition: captures during it are `unbound` with NO
  /// hint. At a plain sign-out the hint stays so the same uid can recover them.
  static func clearActiveOwner(clearHint: Bool) throws {
    try withQueueLock {
      try removeKeychain(forKey: activeOwnerKC)
      if clearHint { try removeKeychain(forKey: lastAdmittedHashKC) }
      bumpOwnerEpoch()
      defaults?.synchronize()
    }
  }

  /// Per-owner consent mirror (advisory; read by the intent for the stamped
  /// owner only). Keyed by uidHash; deleted by the Remove-data sweep.
  static func setConsentMirror(uid: String, cloud: Bool, ai: Bool, version: Int) throws {
    try withQueueLock {
      // A-12-min R4: refused while a Remove-data barrier is in force.
      guard try readBarrier() == nil else { throw QueueError.barrierActive }
      writeConsentMirrorEntry(
        hash: try uidHash(uid),
        mirror: ConsentMirrorValue(cloud: cloud, ai: ai, version: version)
      )
    }
  }

  /// Writes one mirror entry. Callers hold the queue flock.
  private static func writeConsentMirrorEntry(hash: String, mirror: ConsentMirrorValue) {
    var entries = defaults?.dictionary(forKey: consentMirrorKey) ?? [:]
    entries[hash] = ["cloud": mirror.cloud, "ai": mirror.ai, "version": mirror.version]
    defaults?.set(entries, forKey: consentMirrorKey)
    defaults?.synchronize()
  }

  private static func consentMirror(forHash hash: String) -> (cloud: Bool, ai: Bool)? {
    guard let entry = defaults?.dictionary(forKey: consentMirrorKey)?[hash] as? [String: Any],
          let cloud = entry["cloud"] as? Bool,
          let ai = entry["ai"] as? Bool else {
      return nil
    }
    return (cloud, ai)
  }

  /// §4.2 "before any upload": re-reads `{uid, generation}` under the flock and
  /// allows the upload only if it is still the one the item was stamped under,
  /// the item is not local-only, and the stamped owner's consent mirror EXISTS
  /// and says cloud ON. Fails closed. EVERY upload path (the App Intent and the
  /// app's pendingSend replay) must call this first (A-12-min R2).
  static func authorizeUpload(payloadID: String) -> UploadDecision {
    (try? withQueueLock { () throws -> UploadDecision in
      guard try readBarrier() == nil else { return .waiting }
      guard let item = try loadQueue().first(where: { $0.id == payloadID }) else {
        return .waiting
      }
      if item.ownerState == ownerStateUnbound { return .localOnly }
      guard item.ownerState == ownerStateStamped,
            let uid = item.ownerUid,
            let generation = item.ownerGeneration,
            let owner = try readActiveOwner(),
            owner.uid == uid, owner.generation == generation else {
        return .waiting
      }
      if item.localOnly == true { return .localOnly }
      // A-12-min R2: fail closed. No mirror means nothing is known about this
      // owner's consent, so the item waits; it is never `allowed` by default.
      guard let mirror = consentMirror(forHash: owner.uidHash) else { return .waiting }
      return mirror.cloud ? .allowed(ownerUid: uid, allowAi: mirror.ai) : .localOnly
    }) ?? .waiting
  }

  // MARK: Unbound recovery (§4.3)

  /// Count/senders of the unbound items whose hint is HMAC([uid]). Items without
  /// a hint, or hinted to another uid, are never reported.
  static func unboundSummary(forUid uid: String) throws -> UnboundSummary {
    try withQueueLock {
      let hash = try uidHash(uid)
      let mine = try loadQueuePruned().filter {
        $0.ownerState == ownerStateUnbound && $0.ownerHint == hash
      }
      let senders = Array(Set(mine.compactMap { $0.sender })).sorted()
      return UnboundSummary(ids: mine.compactMap { $0.id }, senders: senders)
    }
  }

  /// "Add them to my account": binds the [ids] snapshot under the flock iff every
  /// item is still unbound AND hinted to [uid], the active owner record is
  /// exactly `{uid, generation}`, and replica owner and session uid both equal
  /// [uid]. Otherwise nothing is mutated. Bound items are `localOnly`: they never
  /// upload and never use AI.
  static func claimUnbound(
    uid: String,
    generation: Int,
    replicaOwnerUid: String,
    sessionUid: String,
    ids: [String]
  ) throws -> ClaimOutcome {
    try casUnbound(uid, generation, replicaOwnerUid, sessionUid, ids) { queue, indexes, owner in
      for index in indexes {
        queue[index].ownerState = ownerStateStamped
        queue[index].ownerUid = owner.uid
        queue[index].ownerGeneration = owner.generation
        queue[index].ownerHint = nil
        queue[index].unboundAt = nil
        queue[index].localOnly = true
        if queue[index].status == CaptureStatus.pendingSend.rawValue {
          queue[index].status = CaptureStatus.sent.rawValue
        }
      }
    }
  }

  /// "Discard them": the same CAS, then deletes the items.
  static func discardUnbound(
    uid: String,
    generation: Int,
    replicaOwnerUid: String,
    sessionUid: String,
    ids: [String]
  ) throws -> ClaimOutcome {
    try casUnbound(uid, generation, replicaOwnerUid, sessionUid, ids) { queue, indexes, _ in
      for index in indexes.sorted(by: >) { queue.remove(at: index) }
    }
  }

  private static func casUnbound(
    _ uid: String,
    _ generation: Int,
    _ replicaOwnerUid: String,
    _ sessionUid: String,
    _ ids: [String],
    apply: (inout [Payload], [Int], OwnerRecord) -> Void
  ) throws -> ClaimOutcome {
    try withQueueLock {
      guard try readBarrier() == nil else { throw QueueError.barrierActive }
      let target = normalizedUID(uid)
      guard normalizedUID(replicaOwnerUid) == target,
            normalizedUID(sessionUid) == target,
            let owner = try readActiveOwner(),
            owner.uid == target, owner.generation == generation else {
        return .ownerMismatch
      }
      let hash = try uidHash(target)
      var queue = try loadQueuePruned()
      let wanted = Set(ids)
      let indexes = queue.indices.filter { wanted.contains(queue[$0].id ?? "") }
      guard !wanted.isEmpty, indexes.count == wanted.count,
            indexes.allSatisfy({
              queue[$0].ownerState == ownerStateUnbound && queue[$0].ownerHint == hash
            }) else {
        return .stale
      }
      apply(&queue, indexes, owner)
      try saveQueue(queue, notifyHost: false)
      return .applied(indexes.count)
    }
  }

  // MARK: Legacy v2 provenance (§4.7)

  /// Dart's adopted-replica verdict on migrated items: [consumedIds] (receipt
  /// `capture_payload:<id>` or tx.id == capture_id) are removed; [suspectedIds]
  /// (fingerprint match) get the non-financial `suspected_already_imported`
  /// annotation. Only `legacy_v2` unbound items are touched; nothing is bound.
  @discardableResult
  static func resolveLegacyItems(consumedIds: [String], suspectedIds: [String]) throws -> Int {
    try withQueueLock {
      var queue = try loadQueue()
      let consumed = Set(consumedIds)
      let suspected = Set(suspectedIds)
      let before = queue.count
      func isLegacy(_ item: Payload) -> Bool {
        item.origin == originLegacyV2 && item.ownerState == ownerStateUnbound
      }
      queue.removeAll(where: { isLegacy($0) && consumed.contains($0.id ?? "") })
      for index in queue.indices
      where isLegacy(queue[index]) && suspected.contains(queue[index].id ?? "") {
        queue[index].reviewState = reviewSuspectedAlreadyImported
      }
      try saveQueue(queue, notifyHost: false)
      return before - queue.count
    }
  }

  /// One migrated v2 item as the legacy resolver needs it for the A6
  /// fingerprint check. Content-bearing: never log it.
  struct LegacyPeekItem {
    let id: String
    let text: String
    let receivedAt: String?
    let createdAt: String?
  }

  /// A6 (CAP-7): read-only listing of the `legacy_v2` items that are still
  /// unbound. Under the flock; changes nothing and notifies nobody.
  static func peekLegacyCaptureItems() throws -> [LegacyPeekItem] {
    try withQueueLock {
      try loadQueue().compactMap { item in
        guard item.origin == originLegacyV2,
              item.ownerState == ownerStateUnbound,
              let id = item.id else { return nil }
        return LegacyPeekItem(
          id: id, text: item.text, receivedAt: item.receivedAt, createdAt: item.createdAt
        )
      }
    }
  }

  // MARK: Remove-data barrier (§4.4)

  private static func readBarrier() throws -> RemovalBarrier? {
    let url = try appGroupContainerURL().appendingPathComponent(barrierFileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    // An unreadable barrier fails closed: the capture is refused, not persisted.
    guard let data = try? Data(contentsOf: url),
          let barrier = try? JSONDecoder().decode(RemovalBarrier.self, from: data) else {
      throw QueueError.unreadable
    }
    return barrier
  }

  /// Step 1 of Remove data for [uid]: under the flock, persist the barrier and
  /// clear the owner record if it is [uid]'s. From now on the intent fails
  /// visibly instead of persisting. Idempotent for the same uid (a resumed removal).
  static func beginRemoval(uid: String) throws -> RemovalBarrier {
    try withQueueLock {
      let target = normalizedUID(uid)
      let hash = try uidHash(target)
      let barrier: RemovalBarrier
      if let existing = try readBarrier() {
        guard existing.uidHash == hash else { throw QueueError.barrierActive }
        barrier = existing
      } else {
        barrier = RemovalBarrier(
          nonce: UUID().uuidString.lowercased(),
          uidHash: hash,
          startedAt: isoFormatter.string(from: Date())
        )
        guard let data = try? JSONEncoder().encode(barrier) else { throw QueueError.encodingFailed }
        do {
          try data.write(
            to: try appGroupContainerURL().appendingPathComponent(barrierFileName),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
          )
        } catch let error as QueueError {
          throw error
        } catch {
          throw QueueError.storageWriteFailed
        }
      }
      if let owner = try readActiveOwner(), owner.uid == target {
        try removeKeychain(forKey: activeOwnerKC)
        bumpOwnerEpoch()
      }
      return barrier
    }
  }

  /// The barrier in force, if any. A launch that finds one resumes the removal
  /// from step 2 (replica teardown), then calls `finishRemoval`.
  static func removalBarrier() throws -> RemovalBarrier? {
    try withQueueLock { try readBarrier() }
  }

  /// Step 5 of Remove data: the final sweep under the flock. Deletes every item
  /// owned by, hinted to, or created at/after the barrier start of [uid]'s
  /// removal (or tagged with its nonce), drops the uid's consent mirror and
  /// last-admitted hint, and clears the barrier LAST so a crash re-runs this
  /// idempotently. Returns the number of items deleted.
  @discardableResult
  static func finishRemoval(uid: String) throws -> Int {
    try withQueueLock {
      guard let barrier = try readBarrier() else { return 0 }
      let target = normalizedUID(uid)
      let hash = try uidHash(target)
      guard barrier.uidHash == hash else { throw QueueError.barrierActive }
      var queue = try loadQueue()
      let started = isoFormatter.date(from: barrier.startedAt)
      let before = queue.count
      queue.removeAll(where: { item in
        if item.ownerUid == target || item.ownerHint == hash { return true }
        if item.barrierNonce == barrier.nonce { return true }
        if let started = started,
           let created = item.createdAt.flatMap(isoFormatter.date(from:)),
           created >= started {
          return true
        }
        return false
      })
      try saveQueue(queue, notifyHost: false)
      if try readLastAdmittedHash() == hash { try removeKeychain(forKey: lastAdmittedHashKC) }
      if let owner = try readActiveOwner(), owner.uid == target {
        try removeKeychain(forKey: activeOwnerKC)
        bumpOwnerEpoch()
      }
      var mirror = defaults?.dictionary(forKey: consentMirrorKey) ?? [:]
      mirror.removeValue(forKey: hash)
      defaults?.set(mirror, forKey: consentMirrorKey)
      defaults?.synchronize()
      let url = try appGroupContainerURL().appendingPathComponent(barrierFileName)
      do {
        try FileManager.default.removeItem(at: url)
      } catch {
        throw QueueError.storageWriteFailed
      }
      return before - queue.count
    }
  }

  // MARK: Queue stats (diagnostics, content-free)

  enum QuotaState: String, Equatable {
    case ok
    /// At least 80% of a count or byte limit.
    case near
    /// The next capture in this scope would be refused (§4.5).
    case full
  }

  /// WP-8 diagnostics: counts, byte sizes and quota state ONLY. No text, sender,
  /// amount, merchant, account, id or uid ever appears here, and there is no
  /// per-capture list. Each item falls in exactly one bucket: `unbound`;
  /// stamped to the active owner (`localOnly` when it never uploads, else
  /// `stamped`); anything else (another owner's, or no owner is active) is
  /// `waiting`.
  struct QueueStats: Equatable {
    var stamped = 0
    var localOnly = 0
    var waiting = 0
    var unbound = 0
    var activeOwnerBytes = 0
    var unboundBytes = 0
    var deviceBytes = 0
    var ownerQuota = QuotaState.ok
    var unboundQuota = QuotaState.ok
    var deviceQuota = QuotaState.ok
    /// The v2 queue has not been migrated to v3 yet. Its items are counted as
    /// unbound (what the migration will make them) WITHOUT migrating.
    var migrationPending = false
  }

  /// The queue for stats: STRICTLY read-only. Unlike `loadQueue` it never runs
  /// the one-time v2 -> v3 migration (a write); a not-yet-migrated v2 blob is
  /// counted as the unbound items the migration will make of it.
  private static func loadQueueReadOnly() throws -> (queue: [Payload], migrationPending: Bool) {
    if let data = try readQueueFile() { return (try decodeQueueBlob(data), false) }
    guard defaults?.bool(forKey: migratedKey) != true,
          let blob = defaults?.data(forKey: queueKey) else { return ([], false) }
    return (try decodeQueueBlob(blob).map { quarantinedLegacy($0, at: "") }, true)
  }

  /// Read-only, under the flock (writes nothing, migrates nothing). The limits
  /// are the §4.5 shipping values.
  static func queueStats() throws -> QueueStats {
    try withQueueLock {
      let (queue, migrationPending) = try loadQueueReadOnly()
      let owner = try readActiveOwner()
      var stats = QueueStats()
      stats.migrationPending = migrationPending
      var ownerItems = 0
      func size(_ value: Payload) throws -> Int {
        guard let data = try? JSONEncoder().encode(value) else { throw QueueError.encodingFailed }
        return data.count
      }
      for item in queue {
        let bytes = try size(item)
        stats.deviceBytes += bytes
        if item.ownerState == ownerStateUnbound {
          stats.unbound += 1
          stats.unboundBytes += bytes
        } else if let owner = owner, item.ownerUid == owner.uid {
          ownerItems += 1
          stats.activeOwnerBytes += bytes
          if item.localOnly == true { stats.localOnly += 1 } else { stats.stamped += 1 }
        } else {
          stats.waiting += 1
        }
      }
      func state(count: Int, maxCount: Int?, bytes: Int, maxBytes: Int) -> QuotaState {
        if bytes >= maxBytes || (maxCount.map { count >= $0 } ?? false) { return .full }
        if bytes * 5 >= maxBytes * 4 || (maxCount.map { count * 5 >= $0 * 4 } ?? false) {
          return .near
        }
        return .ok
      }
      stats.ownerQuota = state(
        count: ownerItems, maxCount: ownerMaxItems,
        bytes: stats.activeOwnerBytes, maxBytes: ownerMaxBytes)
      stats.unboundQuota = state(
        count: stats.unbound, maxCount: unboundMaxItems,
        bytes: stats.unboundBytes, maxBytes: unboundMaxBytes)
      stats.deviceQuota = state(
        count: queue.count, maxCount: nil, bytes: stats.deviceBytes, maxBytes: deviceMaxBytes)
      return stats
    }
  }

  /// Every queued item, for diagnostics and tests. Content-bearing: never log it.
  static func queueSnapshot() throws -> [Payload] {
    try withQueueLock { try loadQueue() }
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

  @discardableResult
  static func remove(forKey key: String) -> OSStatus {
    SecItemDelete(baseQuery(key) as CFDictionary)
  }
}
