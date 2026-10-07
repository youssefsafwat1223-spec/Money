import Flutter
import UIKit
import XCTest

@testable import Runner

class RunnerTests: XCTestCase {

  func testShortcutPersistsBeforeNetworkAndUsesStablePayloadID() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("BankMessageShortcuts/BankMessageShortcuts.swift")
    )
    let persist = try XCTUnwrap(source.range(of: "status: .pendingSend"))
    let network = try XCTUnwrap(source.range(of: "let attempt = await processBackend"))
    XCTAssertLessThan(persist.lowerBound, network.lowerBound)
  }

  /// H-19 durability contract: on a SUCCESSFUL backend capture the App Intent
  /// must RETAIN the durable local copy (mark it `.sent`) rather than delete it.
  /// Deleting it made processed_captures (swept unconditionally at 30 days) the
  /// only copy, so an unopened app lost a capture the user was told succeeded.
  /// This fails against the pre-fix source, which called
  /// `SharedCaptureStore.remove(payloadID: payloadID)` on success.
  func testShortcutRetainsDurableCopyOnBackendSuccess() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("BankMessageShortcuts/BankMessageShortcuts.swift")
    )
    // The success branch begins at `if let response = attempt.response`.
    let successBranch = try XCTUnwrap(source.range(of: "if let response = attempt.response"))
    let branchTail = String(source[successBranch.lowerBound...])
    XCTAssertTrue(
      branchTail.contains("SharedCaptureStore.updateStatus(payloadID: payloadID, status: .sent)"),
      "backend success must keep a durable local copy as .sent for the host drain to import"
    )
    XCTAssertFalse(
      source.contains("SharedCaptureStore.remove(payloadID: payloadID)"),
      "the App Intent must NOT delete the only durable local copy on backend success (H-19)"
    )
  }

  /// The two physical copies of SharedCaptureStore.swift (Runner + the Share
  /// Extension; the App Intent target compiles one of them via membership) must
  /// stay byte-identical.
  func testSharedCaptureStoresRemainByteIdentical() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let paths = [
      "Runner/SharedCaptureStore.swift",
      "ShareBankMessage/SharedCaptureStore.swift",
    ]
    let values = try paths.map {
      try Data(contentsOf: root.appendingPathComponent($0))
    }
    XCTAssertEqual(values[0], values[1])
  }

  /// A-12-min R4: publishing writes the owner's consent mirror with the owner, in
  /// one flock, compare-and-swap on the owner epoch. The default is Cloud ON, so
  /// the stamped items are upload-eligible exactly as before A-12-min.
  @discardableResult
  private func publish(
    _ uid: String, cloud: Bool = true, ai: Bool = false, version: Int = 1
  ) throws -> SharedCaptureStore.OwnerRecord {
    try SharedCaptureStore.publishActiveOwner(
      uid: uid,
      mirror: SharedCaptureStore.ConsentMirrorValue(cloud: cloud, ai: ai, version: version),
      expectedEpoch: try SharedCaptureStore.ownerEpoch())
  }

  private var appGroupDefaults: UserDefaults {
    UserDefaults(suiteName: SharedCaptureStore.appGroupIdentifier)!
  }

  private var container: URL {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: SharedCaptureStore.appGroupIdentifier)!
  }

  /// CAP-6: queue v3 is an encrypted file in the App Group container.
  private var queueFileURL: URL {
    container.appendingPathComponent("pending_bank_messages_v3.bin")
  }

  private func queueFileData() -> Data? { try? Data(contentsOf: queueFileURL) }

  private let ownerA = "11111111-1111-4111-8111-111111111111"
  private let ownerB = "22222222-2222-4222-8222-222222222222"

  // MALI-031 — the capture queue is encrypted at rest; the raw SMS never appears
  // as plaintext in App Group UserDefaults, but round-trips out via the store.
  func testCaptureQueueEncryptedAtRestAndRoundTrips() throws {
    SharedCaptureStore.purgeUserOwnedState()
    try publish(ownerA)
    let secret = "ACME: purchase 512.34 SAR on card 4417"
    let result = SharedCaptureStore.enqueue(text: secret, sender: "ACME")
    if case .failed(let reason, _) = result { XCTFail("enqueue failed: \(reason)") }

    let json = try XCTUnwrap(SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertTrue(json.contains(secret), "the store must decrypt back to plaintext")

    let blob = try XCTUnwrap(queueFileData())
    let asText = String(data: blob, encoding: .utf8) ?? ""
    XCTAssertFalse(asText.contains(secret), "raw SMS must NOT be stored in plaintext")
    SharedCaptureStore.purgeUserOwnedState()
  }

  // A legacy plaintext-JSON v2 blob is still readable, and (§4.7) migrates to v3
  // as UNBOUND with no hint: never importable by the active owner.
  func testLegacyPlaintextQueueStillReads() throws {
    SharedCaptureStore.purgeUserOwnedState()
    let legacy = "[{\"id\":\"abc\",\"text\":\"legacy 10.00\",\"status\":\"pending\"}]"
    appGroupDefaults.set(Data(legacy.utf8), forKey: "pending_bank_messages_v2")
    try publish(ownerA)
    let items = try SharedCaptureStore.queueSnapshot()
    XCTAssertEqual(items.map { $0.text }, ["legacy 10.00"])
    XCTAssertNil(try SharedCaptureStore.peekPendingPayloadsJSON(),
                 "a migrated item is quarantined, never imported by the active owner")
    SharedCaptureStore.purgeUserOwnedState()
  }

  // A corrupt/undecryptable blob fails closed (empty) and is NOT deleted.
  func testCorruptQueueFailsClosedWithoutDeleting() throws {
    SharedCaptureStore.purgeUserOwnedState()
    let corrupt = Data([0x01, 0x02, 0x03, 0xFF, 0x00, 0x99])
    appGroupDefaults.set(corrupt, forKey: "pending_bank_messages_v2")
    XCTAssertFalse(SharedCaptureStore.hasPendingMessages(), "fail closed → looks empty")
    XCTAssertNotNil(appGroupDefaults.data(forKey: "pending_bank_messages_v2"),
                    "the blob must NOT be deleted on a decrypt failure")
    SharedCaptureStore.purgeUserOwnedState()
  }

  // MALI-031 — the device secret lives in the Keychain, never UserDefaults, and
  // is invalidated by purge.
  func testDeviceSecretNotInUserDefaults() throws {
    SharedCaptureStore.purgeUserOwnedState()
    SharedCaptureStore.setBackendConfig(
      cloudProcessingEnabled: true,
      installID: "install-1",
      deviceSecret: "top-secret-device-key",
      backendURL: "https://example.test",
      anonKey: "anon",
      aiConsentGranted: true
    )
    XCTAssertNil(appGroupDefaults.string(forKey: "device_secret"),
                 "the device secret must not be in App Group UserDefaults")
    XCTAssertEqual(SharedCaptureStore.backendConfig().deviceSecret,
                   "top-secret-device-key",
                   "the secret must round-trip via the Keychain")
    SharedCaptureStore.purgeUserOwnedState()
    XCTAssertNil(SharedCaptureStore.backendConfig().deviceSecret,
                 "purge/wipe invalidates the device secret")
  }

  // ── CAP-0: queue key / lock failures never destroy the queue ───────────────
  //
  // These drive the two internal seams on SharedCaptureStore
  // (queueKeyReadOverride, lockUnavailableOverride). They need a device or
  // simulator with the App Group + Keychain entitlements; they cannot run in
  // the Linux/Dart CI (the Dart source-contract tests pin the same properties).

  private let queueDefaultsKey = "pending_bank_messages_v2"  // legacy v2 blob (migration source)

  private func resetCapSeams() {
    SharedCaptureStore.queueKeyReadOverride = nil
    SharedCaptureStore.lockUnavailableOverride = false
    SharedCaptureStore.ownerRecordReadOverride = nil
    SharedCaptureStore.stampingHook = nil
    SharedCaptureStore.clockOverride = nil
    SharedCaptureStore.egressKeychainReadOverride = nil
    SharedCaptureStore.debugResetCloudEgressState()
    try? FileManager.default.removeItem(
      at: container.appendingPathComponent("capture_destructive_barrier_v1.json"))
    SharedCaptureStore.purgeUserOwnedState()
  }

  // T-Q1: a Keychain read error (errSecInteractionNotAllowed = before first
  // unlock) must not generate a new key or touch the blob. If it had replaced
  // the key, the original blob could no longer be decrypted afterwards.
  func testKeyReadErrorFailsWithoutNewKeyAndKeepsBlob() throws {
    SharedCaptureStore.purgeUserOwnedState()
    defer { resetCapSeams() }
    try publish(ownerA)
    let first = "ACME: purchase 77.10 SAR"
    if case .failed(let reason, _) = SharedCaptureStore.enqueue(text: first, sender: "ACME") {
      return XCTFail("setup enqueue failed: \(reason)")
    }
    let before = try XCTUnwrap(queueFileData())

    SharedCaptureStore.queueKeyReadOverride = { (status: errSecInteractionNotAllowed, data: nil) }
    guard case .failed(_, let kind) = SharedCaptureStore.enqueue(text: "second 5.00 SAR", sender: "ACME") else {
      return XCTFail("enqueue must fail while the key is unreadable")
    }
    XCTAssertEqual(kind, .deviceLocked, "errSecInteractionNotAllowed is the locked-device case")
    XCTAssertThrowsError(try SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertFalse(SharedCaptureStore.remove(payloadID: "anything"))
    XCTAssertEqual(queueFileData(), before, "the encrypted blob must be untouched")

    SharedCaptureStore.queueKeyReadOverride = nil
    let json = try XCTUnwrap(try SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertTrue(json.contains(first), "the original key must still decrypt the blob")
    XCTAssertFalse(json.contains("second 5.00"))
  }

  // T-Q2: no lock, no write. The body never runs unlocked.
  func testLockUnavailableThrowsAndWritesNothing() throws {
    SharedCaptureStore.purgeUserOwnedState()
    defer { resetCapSeams() }
    _ = SharedCaptureStore.enqueue(text: "ACME: purchase 9.00 SAR", sender: "ACME")
    let before = try XCTUnwrap(queueFileData())

    SharedCaptureStore.lockUnavailableOverride = true
    guard case .failed = SharedCaptureStore.enqueue(text: "other 1.00 SAR", sender: "ACME") else {
      return XCTFail("enqueue must fail without the lock")
    }
    XCTAssertThrowsError(try SharedCaptureStore.peekPendingPayloadsJSON()) { error in
      guard case SharedCaptureStore.QueueError.lockUnavailable = error else {
        return XCTFail("unexpected error \(error)")
      }
    }
    XCTAssertFalse(SharedCaptureStore.purgeUserOwnedState(), "an unlocked purge must not run")
    XCTAssertEqual(queueFileData(), before)
  }

  // T-Q3: a blob that cannot be decrypted is not an empty queue; the next
  // enqueue must not overwrite it.
  func testUnreadableBlobIsNeverOverwritten() throws {
    SharedCaptureStore.purgeUserOwnedState()
    defer { resetCapSeams() }
    let corrupt = Data([0x01, 0x02, 0x03, 0xFF, 0x00, 0x99])
    try corrupt.write(to: queueFileURL)
    guard case .failed = SharedCaptureStore.enqueue(text: "new 3.00 SAR", sender: "ACME") else {
      return XCTFail("enqueue must fail on an unreadable blob")
    }
    XCTAssertThrowsError(try SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertEqual(queueFileData(), corrupt)
    // The same holds for an unreadable v2 blob that has not migrated yet.
    SharedCaptureStore.purgeUserOwnedState()
    appGroupDefaults.set(corrupt, forKey: queueDefaultsKey)
    guard case .failed = SharedCaptureStore.enqueue(text: "new 4.00 SAR", sender: "ACME") else {
      return XCTFail("enqueue must fail on an unreadable v2 blob")
    }
    XCTAssertEqual(appGroupDefaults.data(forKey: queueDefaultsKey), corrupt)
    XCTAssertNil(queueFileData(), "no v3 file may be created over an unreadable v2 queue")
  }

  // T-Q4: the App Intent surfaces a persistence failure as a thrown, localized
  // error instead of silently returning a result.
  @available(iOS 16.0, *)
  func testIntentThrowsVisibleErrorWhenQueueUnavailable() async throws {
    SharedCaptureStore.purgeUserOwnedState()
    defer { resetCapSeams() }
    SharedCaptureStore.queueKeyReadOverride = { (status: errSecInteractionNotAllowed, data: nil) }
    let intent = PostBankStatusIntent()
    intent.smsText = "ACME: purchase 12.00 SAR"
    intent.dateReceived = Date()
    do {
      _ = try await intent.perform()
      XCTFail("perform must throw when the capture cannot be persisted")
    } catch let error as ProcessBankSMSError {
      // R9 copy rule: the approved locked-device text, never technical detail.
      let message = try XCTUnwrap(error.errorDescription)
      XCTAssertEqual(message, SharedCaptureStore.FailureKind.deviceLocked.userMessage)
      for leak in ["errSec", "-25308", "keyUnavailable", "OSStatus", "process_bank_sms_error", "%@"] {
        XCTAssertFalse(message.contains(leak), "user-facing error leaked \(leak)")
      }
    } catch {
      XCTFail("unexpected error \(error)")
    }

    intent.smsText = "   "
    do {
      _ = try await intent.perform()
      XCTFail("perform must throw on empty text")
    } catch {
      XCTAssertTrue(error is ProcessBankSMSError)
    }
  }

  // R9: the inferred-date marker round-trips through the queue.
  func testReceivedAtInferredRoundTrips() throws {
    SharedCaptureStore.purgeUserOwnedState()
    defer { resetCapSeams() }
    try publish(ownerA)
    _ = SharedCaptureStore.enqueue(
      text: "ACME: purchase 4.00 SAR", sender: "ACME", receivedAtInferred: true)
    let json = try XCTUnwrap(try SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertTrue(json.contains("\"receivedAtInferred\":true"))
  }


  // ── CAP-6: queue v3 (owner record, stamping, quotas, claim CAS, barrier) ───
  //
  // Device/simulator only (App Group + Keychain). The Dart source-contract test
  // test/architecture/capture_queue_cap6_contract_test.dart pins the same
  // properties on Linux CI.

  @discardableResult
  private func put(_ text: String, sender: String = "ACME") -> SharedCaptureStore.EnqueueResult {
    SharedCaptureStore.enqueue(text: text, sender: sender, source: "ios_shortcut")
  }

  private func items() throws -> [SharedCaptureStore.Payload] {
    try SharedCaptureStore.queueSnapshot()
  }

  // Stamping: owner present -> stamped; none -> unbound + hint; transition -> no hint.
  func testStampingOwnerUnboundHintAndTransition() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA)
    put("stamped 1.00 SAR")
    try SharedCaptureStore.clearActiveOwner(clearHint: false)   // sign-out
    put("signed out 2.00 SAR")
    try SharedCaptureStore.clearActiveOwner(clearHint: true)    // transition
    put("transition 3.00 SAR")

    let queue = try items()
    let stamped = try XCTUnwrap(queue.first { $0.text.hasPrefix("stamped") })
    XCTAssertEqual(stamped.ownerState, "stamped")
    XCTAssertEqual(stamped.ownerUid, ownerA)
    XCTAssertEqual(stamped.ownerGeneration, a.generation)
    XCTAssertNil(stamped.ownerHint)

    let signedOut = try XCTUnwrap(queue.first { $0.text.hasPrefix("signed out") })
    XCTAssertEqual(signedOut.ownerState, "unbound")
    XCTAssertNil(signedOut.ownerUid)
    XCTAssertEqual(signedOut.ownerHint, a.uidHash, "the hint is only the last admitted uidHash")

    let transition = try XCTUnwrap(queue.first { $0.text.hasPrefix("transition") })
    XCTAssertEqual(transition.ownerState, "unbound")
    XCTAssertNil(transition.ownerHint, "a transition capture carries no hint")
  }

  // Non-active owner: A's item waits (not visible to B, not purged) and resumes for A.
  func testNonActiveOwnerItemWaitsAndResumes() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    put("A item 5.00 SAR")
    try publish(ownerB)
    XCTAssertNil(try SharedCaptureStore.peekPendingPayloadsJSON(), "B must not see A's capture")
    XCTAssertFalse(SharedCaptureStore.hasPendingMessages())
    XCTAssertEqual(try items().count, 1, "A's item is not purged")
    try publish(ownerA)
    let json = try XCTUnwrap(try SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertTrue(json.contains("A item 5.00 SAR"))
  }

  // Owner mismatch: an upload is allowed only under the stamped {uid, generation}.
  func testUploadAuthorizationOwnerMismatchAndConsentMirror() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA)
    guard case .enqueued(let item) = put("upload 6.00 SAR") else { return XCTFail("enqueue") }
    let id = try XCTUnwrap(item.id)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: false),
                   "published with a Cloud-ON mirror (ai false)")

    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: true, ai: false, version: 3)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: false))
    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: false, ai: false, version: 4)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly,
                   "cloud OFF in the owner's mirror means zero egress")
    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: true, ai: true, version: 5)

    try publish(ownerB)      // owner changed mid-flight
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .waiting)
    try publish(ownerA)      // same uid, NEW generation
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .waiting,
                   "a changed generation is not 'unchanged'")
    XCTAssertGreaterThan(try XCTUnwrap(SharedCaptureStore.activeOwner()).generation, a.generation)

    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    guard case .enqueued(let unbound) = put("unbound 7.00 SAR") else { return XCTFail("enqueue") }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(unbound.id)),
                   .localOnly, "unbound: zero egress, zero AI")
  }

  // Keychain unavailable while reading the owner record: nothing is persisted.
  func testOwnerRecordUnavailablePersistsNothing() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    put("before 1.00 SAR")
    let before = try XCTUnwrap(queueFileData())
    SharedCaptureStore.ownerRecordReadOverride = { (status: errSecInteractionNotAllowed, data: nil) }
    guard case .failed(_, let kind) = put("during 2.00 SAR") else {
      return XCTFail("enqueue must fail while the owner record is unreadable")
    }
    XCTAssertEqual(kind, .deviceLocked)
    XCTAssertEqual(queueFileData(), before)
  }

  // The owner read, the stamp and the write happen while the flock is held.
  func testFlockHeldDuringStamping() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    var probed = false
    SharedCaptureStore.stampingHook = {
      let fd = open(self.container.appendingPathComponent("pending_bank_messages.lock").path,
                    O_RDWR)
      defer { if fd >= 0 { close(fd) } }
      XCTAssertGreaterThanOrEqual(fd, 0)
      XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "the flock must be held while stamping")
      XCTAssertEqual(errno, EWOULDBLOCK)
      probed = true
    }
    put("locked 8.00 SAR")
    XCTAssertTrue(probed)
  }

  // §4.5 quotas: visible failure, no eviction, exact values.
  func testQuotaValuesAreTheManifestValues() {
    XCTAssertEqual(SharedCaptureStore.ownerMaxItems, 500)
    XCTAssertEqual(SharedCaptureStore.ownerMaxBytes, 2 * 1024 * 1024)
    XCTAssertEqual(SharedCaptureStore.unboundMaxItems, 200)
    XCTAssertEqual(SharedCaptureStore.unboundMaxBytes, 512 * 1024)
    XCTAssertEqual(SharedCaptureStore.deviceMaxBytes, 8 * 1024 * 1024)
    XCTAssertEqual(SharedCaptureStore.unboundExpiryDays, 30)
  }

  func testUnboundCountQuotaFailsVisiblyWithoutEviction() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    for i in 0..<SharedCaptureStore.unboundMaxItems { put("unbound \(i) 1.00 SAR") }
    XCTAssertEqual(try items().count, SharedCaptureStore.unboundMaxItems)
    guard case .failed(_, let kind) = put("one too many 1.00 SAR") else {
      return XCTFail("the 201st unbound capture must be refused")
    }
    XCTAssertEqual(kind, .quotaFull)
    XCTAssertEqual(kind.userMessage, SharedCaptureStore.FailureKind.storageUnavailable.userMessage,
                   "no new copy: the approved storage text is reused until copy is approved")
    XCTAssertEqual(try items().count, SharedCaptureStore.unboundMaxItems, "nothing evicted")
  }

  func testOwnerCountQuotaFailsVisiblyWithoutEviction() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    for i in 0..<SharedCaptureStore.ownerMaxItems { put("owner \(i) 1.00 SAR") }
    guard case .failed(_, let kind) = put("one too many 1.00 SAR") else {
      return XCTFail("the 501st stamped capture must be refused")
    }
    XCTAssertEqual(kind, .quotaFull)
    XCTAssertEqual(try items().count, SharedCaptureStore.ownerMaxItems)
    // Another owner has its own scope.
    try publish(ownerB)
    guard case .enqueued = put("b item 1.00 SAR") else { return XCTFail("B has its own quota") }
  }

  private func big(_ tag: String, _ chars: Int) -> String {
    tag + String(repeating: "x", count: chars)
  }

  func testUnboundAndOwnerByteQuotas() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    for i in 0..<5 { put(big("u\(i)", 100_000)) }            // ~500 KB of 512 KB
    guard case .failed(_, let ubKind) = put(big("u5", 100_000)) else {
      return XCTFail("unbound byte quota must refuse")
    }
    XCTAssertEqual(ubKind, .quotaFull)
    XCTAssertEqual(try items().count, 5)

    SharedCaptureStore.purgeUserOwnedState()
    try publish(ownerA)
    for i in 0..<5 { put(big("o\(i)", 400_000)) }            // ~2.0 MB of 2 MB
    guard case .failed(_, let ownerKind) = put(big("o5", 400_000)) else {
      return XCTFail("per-owner byte quota must refuse")
    }
    XCTAssertEqual(ownerKind, .quotaFull)
    XCTAssertEqual(try items().count, 5)
  }

  func testDeviceByteQuota() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let owners = [ownerA, ownerB,
                  "33333333-3333-4333-8333-333333333333",
                  "44444444-4444-4444-8444-444444444444"]
    for (n, uid) in owners.enumerated() {
      try publish(uid)
      for i in 0..<5 { put(big("d\(n)-\(i)", 400_000)) }    // ~2 MB per owner, ~8 MB total
    }
    try publish("55555555-5555-4555-8555-555555555555")
    guard case .failed(_, let kind) = put(big("e0", 400_000)) else {
      return XCTFail("device-wide 8 MB quota must refuse a fresh owner")
    }
    XCTAssertEqual(kind, .quotaFull)
    XCTAssertEqual(try items().count, 20, "nothing evicted")
  }

  // §4.5 expiry: only UNBOUND items expire by age; stamped items never do.
  func testUnboundExpiresAfter30DaysStampedDoesNot() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    put("stamped keeps 1.00 SAR")
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    put("unbound expires 2.00 SAR")
    SharedCaptureStore.clockOverride = { Date().addingTimeInterval(31 * 86_400) }
    _ = try SharedCaptureStore.peekPendingPayloadsJSON()
    let texts = try items().map { $0.text }
    XCTAssertEqual(texts, ["stamped keeps 1.00 SAR"])
  }

  // §4.7 migration: every v2 item becomes unbound with NO hint; nothing is
  // dropped (quotas do not apply); only Dart's receipt/tx verdict removes items.
  func testV2MigrationQuarantinesEverythingWithoutHint() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let legacy = (0..<(SharedCaptureStore.unboundMaxItems + 50)).map {
      "{\"id\":\"l\($0)\",\"text\":\"legacy \($0) 9.00\",\"status\":\"pendingSend\",\"owner\":\"\(ownerA)\"}"
    }.joined(separator: ",")
    appGroupDefaults.set(Data("[\(legacy)]".utf8), forKey: queueDefaultsKey)
    let a = try publish(ownerA)

    let queue = try items()
    XCTAssertEqual(queue.count, SharedCaptureStore.unboundMaxItems + 50, "no legacy item is dropped")
    for item in queue {
      XCTAssertEqual(item.ownerState, "unbound")
      XCTAssertNil(item.ownerUid)
      XCTAssertNil(item.ownerHint, "no hint is derived from the legacy owner marker")
      XCTAssertEqual(item.origin, "legacy_v2")
    }
    XCTAssertNil(try SharedCaptureStore.peekPendingPayloadsJSON(), "never imported automatically")
    XCTAssertEqual(try SharedCaptureStore.unboundSummary(forUid: ownerA).count, 0,
                   "no hint, so no recovery prompt for anyone")
    XCTAssertNotNil(appGroupDefaults.data(forKey: queueDefaultsKey),
                    "the v2 blob is kept for the 7-day rollback grace")
    XCTAssertGreaterThan(a.generation, 0)

    // Dart's adopted-replica verdict: one consumed (removed), one suspected (annotated).
    let removed = try SharedCaptureStore.resolveLegacyItems(
      consumedIds: ["l0"], suspectedIds: ["l1", "no-such-id"])
    XCTAssertEqual(removed, 1)
    let after = try items()
    XCTAssertEqual(after.count, SharedCaptureStore.unboundMaxItems + 49)
    XCTAssertFalse(after.contains { $0.id == "l0" })
    XCTAssertEqual(after.first { $0.id == "l1" }?.reviewState, "suspected_already_imported")
    XCTAssertNil(after.first { $0.id == "l2" }?.reviewState)
    // The migration ran once: a removed item does not come back.
    XCTAssertFalse(try items().contains { $0.id == "l0" })
  }

  // A6 (CAP-7): the read-only listing returns only unbound legacy_v2 items, with
  // id, raw text and the receive time, and changes nothing.
  func testPeekLegacyCaptureItemsListsOnlyUnboundLegacyAndChangesNothing() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let legacy = "[{\"id\":\"l0\",\"text\":\"legacy 9.00\",\"status\":\"pendingSend\",\"receivedAt\":\"2026-01-02T03:04:05.000Z\"},"
      + "{\"id\":\"l1\",\"text\":\"legacy 8.00\",\"status\":\"pendingSend\"}]"
    appGroupDefaults.set(Data(legacy.utf8), forKey: queueDefaultsKey)
    try publish(ownerA)
    // A stamped, non-legacy item is never listed.
    _ = SharedCaptureStore.enqueue(text: "stamped 7.00", sender: "ACME")

    let before = try items()
    let peeked = try SharedCaptureStore.peekLegacyCaptureItems()
    XCTAssertEqual(Set(peeked.map { $0.id }), ["l0", "l1"])
    XCTAssertEqual(peeked.first { $0.id == "l0" }?.text, "legacy 9.00")
    XCTAssertEqual(peeked.first { $0.id == "l0" }?.receivedAt, "2026-01-02T03:04:05.000Z")
    XCTAssertEqual(try items().count, before.count, "listing mutates nothing")
    XCTAssertEqual(try items().map { $0.reviewState }, before.map { $0.reviewState })
  }

  // CAP-7: the App Intent banner owner rule and the generic text, pinned in the
  // source (the intent target is not importable from RunnerTests).
  func testNotifyV2OwnerRuleAndGenericTextAreWiredInTheIntent() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("BankMessageShortcuts/BankMessageShortcuts.swift")
    )
    XCTAssertTrue(source.contains("response.pushAttempted ?? response.pushSent"))
    XCTAssertTrue(source.contains("json[\"push_attempted\"] as? Bool"))
    XCTAssertTrue(source.contains("\"New transaction captured\""))
    let generic = try XCTUnwrap(source.range(of: "private func scheduleGenericCaptureNotification"))
    let body = String(source[generic.lowerBound...].prefix(600))
    for forbidden in ["amount", "merchant", "last4", "sender", "smsText", "PreviewParser"] {
      XCTAssertFalse(body.contains(forbidden), "generic banner must not touch \(forbidden)")
    }
  }

  // A1/A2 unbound recovery: hint, claim CAS preconditions, no mutation on failure.
  func testUnboundHintAndClaimCAS() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    try SharedCaptureStore.clearActiveOwner(clearHint: false)       // signed out
    put("while signed out 1.00 SAR", sender: "BANK1")
    put("while signed out 2.00 SAR", sender: "BANK2")
    let before = try XCTUnwrap(queueFileData())

    // Another uid authenticates: it sees nothing and cannot claim (A2).
    let b = try publish(ownerB)
    XCTAssertEqual(try SharedCaptureStore.unboundSummary(forUid: ownerB).count, 0)
    let stolen = try SharedCaptureStore.claimUnbound(
      uid: ownerB, generation: b.generation, replicaOwnerUid: ownerB, sessionUid: ownerB,
      ids: try SharedCaptureStore.unboundSummary(forUid: ownerA).ids)
    XCTAssertEqual(stolen, .stale)
    XCTAssertEqual(queueFileData(), before, "a failed claim mutates nothing")

    // The hinted uid returns.
    let a = try publish(ownerA)
    let summary = try SharedCaptureStore.unboundSummary(forUid: ownerA)
    XCTAssertEqual(summary.count, 2)
    XCTAssertEqual(summary.senders, ["BANK1", "BANK2"])

    let uid = ownerA
    func claim(gen: Int, replica: String? = nil, session: String? = nil,
               ids: [String]) throws -> SharedCaptureStore.ClaimOutcome {
      try SharedCaptureStore.claimUnbound(
        uid: uid, generation: gen, replicaOwnerUid: replica ?? uid, sessionUid: session ?? uid, ids: ids)
    }
    XCTAssertEqual(try claim(gen: a.generation + 1, ids: summary.ids), .ownerMismatch)
    XCTAssertEqual(try claim(gen: a.generation, replica: ownerB, ids: summary.ids), .ownerMismatch)
    XCTAssertEqual(try claim(gen: a.generation, session: ownerB, ids: summary.ids), .ownerMismatch)
    XCTAssertEqual(try claim(gen: a.generation, ids: summary.ids + ["unknown"]), .stale)
    XCTAssertEqual(try items().filter { $0.ownerState == "unbound" }.count, 2,
                   "every failed claim left the items unbound")

    XCTAssertEqual(try claim(gen: a.generation, ids: summary.ids), .applied(2))
    let bound = try items()
    for item in bound {
      XCTAssertEqual(item.ownerState, "stamped")
      XCTAssertEqual(item.ownerUid, ownerA)
      XCTAssertEqual(item.localOnly, true, "bound items never upload and never use AI")
      XCTAssertNil(item.ownerHint)
      XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)),
                     .localOnly)
    }
    let json = try XCTUnwrap(try SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertTrue(json.contains("\"localOnly\":true"))
    XCTAssertEqual(try claim(gen: a.generation, ids: summary.ids), .stale, "claims are one-shot")
  }

  func testDiscardUsesTheSameCAS() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    put("discard me 1.00 SAR")
    let a = try publish(ownerA)
    let ids = try SharedCaptureStore.unboundSummary(forUid: ownerA).ids
    XCTAssertEqual(try SharedCaptureStore.discardUnbound(
      uid: ownerA, generation: a.generation, replicaOwnerUid: ownerB, sessionUid: ownerA, ids: ids),
      .ownerMismatch)
    XCTAssertEqual(try items().count, 1)
    XCTAssertEqual(try SharedCaptureStore.discardUnbound(
      uid: ownerA, generation: a.generation, replicaOwnerUid: ownerA, sessionUid: ownerA, ids: ids),
      .applied(1))
    XCTAssertEqual(try items().count, 0)
  }

  // Two claimers race: the flock serializes them; exactly one wins.
  func testClaimRaceTwoClaimersExactlyOneWins() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    put("race 1.00 SAR")
    put("race 2.00 SAR")
    let a = try publish(ownerA)
    let ids = try SharedCaptureStore.unboundSummary(forUid: ownerA).ids
    let lock = NSLock()
    var outcomes: [SharedCaptureStore.ClaimOutcome] = []
    DispatchQueue.concurrentPerform(iterations: 2) { _ in
      let outcome = try? SharedCaptureStore.claimUnbound(
        uid: ownerA, generation: a.generation, replicaOwnerUid: ownerA, sessionUid: ownerA, ids: ids)
      lock.lock(); outcomes.append(outcome ?? .stale); lock.unlock()
    }
    XCTAssertEqual(outcomes.filter { $0 == .applied(2) }.count, 1)
    XCTAssertEqual(outcomes.filter { $0 == .stale }.count, 1)
  }

  // §4.4 Remove-data barrier (A3): the intent fails visibly; the sweep removes
  // everything owned by, hinted to, or created after the barrier for A.
  func testRemovalBarrierBlocksIntentAndSweepsEverythingOfA() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA)
    put("A stamped 1.00 SAR")
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    put("A hinted 2.00 SAR")                                         // hint == uidHash(A)
    let b = try publish(ownerB)
    put("B stamped 3.00 SAR")
    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: true, ai: true, version: 1)
    Thread.sleep(forTimeInterval: 1.1)    // created_at has 1 s resolution

    let barrier = try SharedCaptureStore.beginRemoval(uid: ownerA)
    XCTAssertEqual(barrier.uidHash, a.uidHash)
    XCTAssertEqual(try SharedCaptureStore.beginRemoval(uid: ownerA), barrier, "resumable / idempotent")
    XCTAssertThrowsError(try SharedCaptureStore.beginRemoval(uid: ownerB))
    XCTAssertEqual(try SharedCaptureStore.removalBarrier(), barrier)

    guard case .failed(_, let kind) = put("during removal 4.00 SAR") else {
      return XCTFail("the intent must fail visibly while the barrier is up")
    }
    XCTAssertEqual(kind, .removalInProgress)
    XCTAssertThrowsError(try publish(ownerA))
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: "anything"), .waiting)
    XCTAssertEqual(try items().count, 3, "the refused capture was not persisted")

    XCTAssertEqual(try SharedCaptureStore.finishRemoval(uid: ownerA), 2)
    let left = try items()
    XCTAssertEqual(left.map { $0.text }, ["B stamped 3.00 SAR"], "nothing of A remains")
    XCTAssertNil(try SharedCaptureStore.removalBarrier(), "the barrier is cleared last")
    XCTAssertEqual(try SharedCaptureStore.finishRemoval(uid: ownerA), 0, "idempotent after completion")
    // B stays admitted and keeps working.
    guard case .enqueued = put("after 5.00 SAR") else { return XCTFail("B must capture again") }
    XCTAssertEqual(try SharedCaptureStore.activeOwner(), b)
  }

  // Removing A also forgets A as the last admitted uid: later unbound captures
  // carry no hint, so nothing can ever be recovered "for A".
  func testRemovalClearsLastAdmittedHintWhenItIsA() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    try SharedCaptureStore.clearActiveOwner(clearHint: false)      // sign-out keeps the hint
    _ = try SharedCaptureStore.beginRemoval(uid: ownerA)
    try SharedCaptureStore.finishRemoval(uid: ownerA)
    put("after removal 5.00 SAR")
    let item = try XCTUnwrap(try items().first)
    XCTAssertEqual(item.ownerState, "unbound")
    XCTAssertNil(item.ownerHint)
  }

  // Quota refusal reaches the Share Extension / Shortcut with approved copy only.
  func testNewRefusalKindsReuseApprovedCopyOnly() {
    for kind in [SharedCaptureStore.FailureKind.quotaFull, .removalInProgress, .ownerChanged] {
      XCTAssertEqual(kind.userMessage,
                     SharedCaptureStore.FailureKind.storageUnavailable.userMessage)
    }
    XCTAssertEqual(SharedCaptureStore.FailureKind.quotaFull.bridgeCode, "quota_exceeded")
    XCTAssertEqual(SharedCaptureStore.FailureKind.removalInProgress.bridgeCode, "removal_in_progress")
    XCTAssertEqual(SharedCaptureStore.FailureKind.ownerChanged.bridgeCode, "owner_changed")
  }

  // A re-enqueue goes back under its original owner or not at all.
  func testReEnqueueRequiresOriginalOwner() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerB)
    guard case .failed(_, let kind) = SharedCaptureStore.enqueue(
      text: "back 1.00 SAR", sender: "ACME", requireOwnerUid: ownerA) else {
      return XCTFail("re-enqueue under another owner must be refused")
    }
    XCTAssertEqual(kind, .ownerChanged)
    XCTAssertEqual(try items().count, 0)
  }


  // ── A-12-min: Cloud OFF = zero egress, local owner publication ────────────

  private func mirrorKeyRemoved() {
    appGroupDefaults.removeObject(forKey: "capture_consent_mirror_v1")
  }

  // R3: Cloud OFF at capture time -> the item is local-only for good and a
  // replay-able pendingSend becomes sent, so no drain ever replays it.
  func testCloudOffStampsLocalOnlyAndSentEvenIfCloudIsLaterTurnedOn() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA, cloud: false)
    guard case .enqueued(let item) = SharedCaptureStore.enqueue(
      text: "off 1.00 SAR", sender: "ACME", status: .pendingSend) else { return XCTFail("enqueue") }
    XCTAssertEqual(item.localOnly, true)
    XCTAssertEqual(item.status, "sent", "a localOnly item is never left pendingSend")
    let id = try XCTUnwrap(item.id)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: true, ai: true, version: 2)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly,
                   "consent is judged at capture time: ON later does not make it uploadable")
  }

  func testCloudOnStampsUploadableAndKeepsPendingSend() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA, cloud: true, ai: true)
    guard case .enqueued(let item) = SharedCaptureStore.enqueue(
      text: "on 1.00 SAR", sender: "ACME", status: .pendingSend) else { return XCTFail("enqueue") }
    XCTAssertNil(item.localOnly)
    XCTAssertEqual(item.status, "pendingSend")
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: true))
  }

  // R2/R3: a missing mirror never uploads: new captures are stamped local-only,
  // and an item stamped earlier waits (there is no `.allowed(nil)` any more).
  func testMissingMirrorNeverUploads() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    guard case .enqueued(let early) = put("early 1.00 SAR") else { return XCTFail("enqueue") }
    mirrorKeyRemoved()
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(early.id)), .waiting)
    guard case .enqueued(let late) = SharedCaptureStore.enqueue(
      text: "late 2.00 SAR", sender: "ACME", status: .pendingSend) else { return XCTFail("enqueue") }
    XCTAssertEqual(late.localOnly, true)
    XCTAssertEqual(late.status, "sent")
  }

  // R4: the mirror and the owner are one publish; the owner is never visible
  // without its mirror, and republishing the owner keeps the generation.
  func testPublishWritesMirrorWithOwnerAndKeepsGeneration() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA, cloud: false)
    let again = try publish(ownerA, cloud: true, ai: true, version: 7)
    XCTAssertEqual(again, a)
    guard case .enqueued(let item) = put("mirror 3.00 SAR") else { return XCTFail("enqueue") }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: true))
  }

  // R4: compare-and-swap. A publish that read its epoch before a transition
  // clear is refused afterwards, so B's capture is never stamped as A's.
  func testLatePublishAfterTransitionClearIsRefused() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let epoch = try SharedCaptureStore.ownerEpoch()          // A's publish starts here
    try SharedCaptureStore.clearActiveOwner(clearHint: true)  // transition clear
    XCTAssertGreaterThan(try SharedCaptureStore.ownerEpoch(), epoch)
    XCTAssertThrowsError(try SharedCaptureStore.publishActiveOwner(
      uid: ownerA,
      mirror: SharedCaptureStore.ConsentMirrorValue(cloud: true, ai: false, version: 1),
      expectedEpoch: epoch)) { error in
      guard case SharedCaptureStore.QueueError.ownerChanged = error else {
        return XCTFail("expected ownerChanged, got \(error)")
      }
    }
    XCTAssertNil(try SharedCaptureStore.activeOwner())
    guard case .enqueued(let item) = put("B capture 4.00 SAR") else { return XCTFail("enqueue") }
    XCTAssertEqual(item.ownerState, "unbound")
    XCTAssertNil(item.ownerUid, "a late A publish must never own B's capture")
  }

  // R4: setConsentMirror is refused while a Remove-data barrier is in force.
  func testSetConsentMirrorRefusedUnderBarrier() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    _ = try SharedCaptureStore.beginRemoval(uid: ownerA)
    XCTAssertThrowsError(try SharedCaptureStore.setConsentMirror(
      uid: ownerA, cloud: true, ai: true, version: 9))
  }

  // The claim path binds items local-only and forces pendingSend -> sent.
  func testClaimForcesSentAndLocalOnly() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA)
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    SharedCaptureStore.enqueue(text: "pending 1.00 SAR", sender: "ACME", status: .pendingSend)
    let a2 = try publish(ownerA)
    let hinted = try SharedCaptureStore.unboundSummary(forUid: ownerA)
    XCTAssertEqual(hinted.count, 1)
    _ = a
    XCTAssertEqual(
      try SharedCaptureStore.claimUnbound(
        uid: ownerA, generation: a2.generation, replicaOwnerUid: ownerA,
        sessionUid: ownerA, ids: hinted.ids),
      .applied(1))
    let claimed = try XCTUnwrap(try items().first)
    XCTAssertEqual(claimed.localOnly, true)
    XCTAssertEqual(claimed.status, "sent")
  }

  // ── captureQueueStats (content-free) ──────────────────────────────────────

  func testQueueStatsBucketsBytesAndQuotaState() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerB)
    put("B waits 1.00 SAR")
    try publish(ownerA, cloud: false)
    put("A local only 2.00 SAR")                  // stamped localOnly (Cloud OFF)
    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: true, ai: false, version: 2)
    put("A stamped 3.00 SAR")
    try SharedCaptureStore.clearActiveOwner(clearHint: true)
    put("unbound 4.00 SAR")

    let stats = try SharedCaptureStore.queueStats()
    XCTAssertEqual(stats.stamped, 0, "no active owner now: A's items wait")
    XCTAssertEqual(stats.waiting, 3)
    XCTAssertEqual(stats.unbound, 1)
    XCTAssertGreaterThan(stats.deviceBytes, 0)
    XCTAssertEqual(stats.unboundQuota, .ok)
    XCTAssertEqual(stats.deviceQuota, .ok)

    try publish(ownerA)
    let active = try SharedCaptureStore.queueStats()
    XCTAssertEqual(active.stamped, 1)
    XCTAssertEqual(active.localOnly, 1)
    XCTAssertEqual(active.waiting, 1)
    XCTAssertEqual(active.unbound, 1)
    XCTAssertEqual(active.stamped + active.localOnly + active.waiting + active.unbound,
                   try items().count, "every item is in exactly one bucket")
    XCTAssertGreaterThan(active.activeOwnerBytes, 0)
    XCTAssertLessThanOrEqual(active.activeOwnerBytes + active.unboundBytes, active.deviceBytes)
  }

  // Stats never write: an unmigrated v2 queue is counted, not migrated.
  func testQueueStatsNeverMigratesTheV2Queue() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let legacy = "[{\"id\":\"abc\",\"text\":\"legacy 10.00\",\"status\":\"pending\"}]"
    appGroupDefaults.set(Data(legacy.utf8), forKey: "pending_bank_messages_v2")
    let stats = try SharedCaptureStore.queueStats()
    XCTAssertTrue(stats.migrationPending)
    XCTAssertEqual(stats.unbound, 1)
    XCTAssertNil(queueFileData(), "no v3 file was written by a stats read")
    XCTAssertNil(appGroupDefaults.object(forKey: "pending_bank_messages_v3_migrated"),
                 "the migration flag was not set by a stats read")
  }

  // A localOnly item that is still `.pending` (not pendingSend) can never be
  // authorized for upload either, whatever the mirror says later.
  func testLocalOnlyPendingItemIsNeverAuthorized() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA, cloud: false)
    guard case .enqueued(let item) = SharedCaptureStore.enqueue(
      text: "pending 1.00 SAR", sender: "ACME", status: .pending) else { return XCTFail("enqueue") }
    XCTAssertEqual(item.localOnly, true)
    XCTAssertEqual(item.status, "pending")
    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: true, ai: true, version: 3)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)), .localOnly)
  }

  func testQueueStatsReadOnlyAndContentFree() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    put("SECRET-TEXT 5.00 SAR", sender: "SECRET-SENDER")
    let before = try XCTUnwrap(queueFileData())
    let stats = try SharedCaptureStore.queueStats()
    XCTAssertEqual(queueFileData(), before, "stats never write the queue")
    let described = String(describing: stats)
    for fragment in ["SECRET", ownerA, "5.00"] {
      XCTAssertFalse(described.contains(fragment), "stats must be content-free")
    }
  }


  // ── APNs environment pairing ───────────────────────────────────────────────
  //
  // A real iPhone registered a SANDBOX token as `production` because the old
  // derivation was `#if DEBUG`, and DEBUG is not defined in this project's
  // Swift build conditions. These pin the replacement: the value comes from the
  // signed entitlement, and anything unresolved withholds the token.

  private func profileBlob(withEntitlements body: String) -> Data {
    // A provisioning profile is a plist wrapped in a CMS/DER envelope; the
    // parser slices the plist out of the surrounding bytes.
    let plist = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"       "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict><key>Name</key><string>t</string>      <key>Entitlements</key><dict>\(body)</dict></dict></plist>
      """
    var data = Data([0x30, 0x82, 0x0A, 0xBC, 0x06, 0x09])
    data.append(plist.data(using: .isoLatin1)!)
    data.append(Data([0x00, 0x01, 0x02]))
    return data
  }

  func testApnsDevelopmentEntitlementMapsToSandbox() {
    XCTAssertEqual(ApnsEnvironment.map(entitlement: "development"), "sandbox")
  }

  func testApnsProductionEntitlementMapsToProduction() {
    XCTAssertEqual(ApnsEnvironment.map(entitlement: "production"), "production")
  }

  func testApnsMissingEntitlementIsUnresolved() {
    XCTAssertNil(ApnsEnvironment.map(entitlement: nil))
  }

  func testApnsUnexpectedEntitlementIsUnresolved() {
    // Including case variants: the entitlement vocabulary is exact.
    for value in ["", "staging", "sandbox", "Development", "PRODUCTION", "dev"] {
      XCTAssertNil(
        ApnsEnvironment.map(entitlement: value),
        "\(value) must not resolve to an APNs host")
    }
  }

  func testApnsEntitlementReadFromProvisioningProfile() {
    let dev = profileBlob(
      withEntitlements: "<key>aps-environment</key><string>development</string>")
    XCTAssertEqual(ApnsEnvironment.entitlement(inProfile: dev), "development")
    XCTAssertEqual(
      ApnsEnvironment.map(entitlement: ApnsEnvironment.entitlement(inProfile: dev)),
      "sandbox")

    let prod = profileBlob(
      withEntitlements: "<key>aps-environment</key><string>production</string>")
    XCTAssertEqual(
      ApnsEnvironment.map(entitlement: ApnsEnvironment.entitlement(inProfile: prod)),
      "production")
  }

  func testApnsProfileWithoutEntitlementIsUnresolved() {
    // Push capability absent from the profile: no token may be registered.
    let none = profileBlob(
      withEntitlements: "<key>application-identifier</key><string>X.y</string>")
    XCTAssertNil(ApnsEnvironment.entitlement(inProfile: none))
    XCTAssertNil(
      ApnsEnvironment.map(entitlement: ApnsEnvironment.entitlement(inProfile: none)))
  }

  func testApnsGarbageProfileIsUnresolved() {
    XCTAssertNil(ApnsEnvironment.entitlement(inProfile: Data([0x00, 0xFF, 0x10])))
  }

  func testApnsMissingProfileWithStoreReceiptIsProduction() {
    // App Store / TestFlight: Apple strips the profile and re-signs for the
    // production APNs host. The RECEIPT is the evidence; failing closed here
    // would stop every shipping build from registering for push.
    XCTAssertEqual(
      ApnsEnvironment.resolve(profileData: nil, isStoreDistributed: true),
      "production")
  }

  func testApnsMissingProfileWithoutStoreReceiptFailsClosed() {
    // No profile AND no receipt: nothing establishes the environment, so the
    // token must be withheld rather than guessed as production.
    XCTAssertNil(
      ApnsEnvironment.resolve(profileData: nil, isStoreDistributed: false))
  }

  func testApnsStoreEvidenceCannotOverrideAPresentProfile() {
    // A development profile stays sandbox even if a receipt is somehow present:
    // the signed profile is the stronger, more specific evidence.
    let dev = profileBlob(
      withEntitlements: "<key>aps-environment</key><string>development</string>")
    XCTAssertEqual(
      ApnsEnvironment.resolve(profileData: dev, isStoreDistributed: true),
      "sandbox")
  }

  func testApnsDevelopmentBundleIsNotTreatedAsStoreDistributed() {
    // The test bundle has no App Store receipt, so the real accessor must say
    // so — this is what makes the missing-profile branch safe.
    XCTAssertFalse(
      ApnsEnvironment.isStoreDistributed(bundle: Bundle(for: RunnerTests.self)))
    XCTAssertNil(
      ApnsEnvironment.current(bundle: Bundle(for: RunnerTests.self)),
      "a bundle with neither a profile nor a receipt must fail closed")
  }

  func testApnsRoutingDoesNotDependOnDebugCompileFlag() throws {
    // The dead `#if DEBUG` branch is what shipped the defect. Assert the
    // registration handler derives the environment from the entitlement.
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Runner/AppDelegate.swift"))
    let start = try XCTUnwrap(
      source.range(of: "didRegisterForRemoteNotificationsWithDeviceToken"))
    let end = try XCTUnwrap(
      source.range(of: "didFailToRegisterForRemoteNotificationsWithError"))
    let handler = String(source[start.upperBound..<end.lowerBound])
    XCTAssertFalse(
      handler.contains("#if DEBUG"),
      "APNs environment must never come from a compile flag")
    XCTAssertTrue(handler.contains("ApnsEnvironment.current()"))
    XCTAssertTrue(
      handler.contains("guard let environment"),
      "an unresolved environment must withhold the token")
  }

  // MARK: - G3 cloud-egress denial state (C.4 / C.5), C.1 owner binding, P4 / P6

  private var egressFileURL: URL { container.appendingPathComponent("cloud_egress_state_v1.json") }
  private var inflightFileURL: URL { container.appendingPathComponent("native_inflight_uploads_v1.json") }

  private typealias Rec = SharedCaptureStore.CloudEgressRecord

  private func rec(_ state: String, _ generation: Int) -> Rec {
    Rec(state: state, transitionGeneration: generation, reservedVersion: generation + 1)
  }

  /// The stored map JSON: one entry per owner, keyed by uidHash.
  private func egressJSON(_ entries: [(String, String, Int)]) throws -> Data {
    var owners: [String: Rec] = [:]
    for (uid, state, generation) in entries {
      owners[try SharedCaptureStore.debugOwnerHash(uid)] = rec(state, generation)
    }
    return try JSONEncoder().encode(SharedCaptureStore.CloudEgressMap(owners: owners))
  }

  private func egressState(_ uid: String) throws -> SharedCaptureStore.EgressSnapshot {
    try SharedCaptureStore.cloudEgressState(forUid: uid)
  }

  /// An item stamped to A under a Cloud-ON mirror, upload-eligible until a denial.
  private func stampedAllowedItem() throws -> (id: String, record: SharedCaptureStore.OwnerRecord) {
    let a = try publish(ownerA, cloud: true, ai: true)
    guard case .enqueued(let item) = put("egress 5.00 SAR") else { XCTFail("enqueue"); throw QueueTestError.enqueue }
    let id = try XCTUnwrap(item.id)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: true))
    return (id, a)
  }

  private enum QueueTestError: Error { case enqueue }

  // D5 (native): a corrupt egress FILE denies; the item stays local-only.
  func testCorruptEgressFileDeniesEgress() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 1, reservedVersion: 2)
    XCTAssertNotEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    try Data([0x00, 0xFF, 0x7B]).write(to: egressFileURL)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    XCTAssertEqual(try egressState(ownerA), .uncertain)
    XCTAssertEqual(try egressState(ownerB), .uncertain, "an unreadable store denies every owner")
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())
    // A restrictive write repairs the corrupt file (a valid OFF in either store wins).
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 3)
    XCTAssertEqual(try egressState(ownerA), .record(rec("OFF", 2)))
  }

  // D5 (native): an UNREADABLE Keychain copy denies (never "treated as absent").
  func testUnreadableEgressKeychainDeniesEgress() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    SharedCaptureStore.egressKeychainReadOverride = { (errSecInteractionNotAllowed, nil) }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    XCTAssertEqual(try egressState(ownerA), .uncertain)
    SharedCaptureStore.egressKeychainReadOverride = { (errSecSuccess, Data([0x01, 0x02])) }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly,
                   "undecodable Keychain bytes are corrupt, not absent")
    // With no readable store at all, an ON write cannot widen over the corruption.
    XCTAssertThrowsError(try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 9, reservedVersion: 10))
  }

  // D4 (native part): mixed-store records. A valid DISABLING/OFF in EITHER store
  // wins over ON or absence in the other.
  func testMixedStoreDisablingRecordWinsInEitherStore() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 3, reservedVersion: 4)
    XCTAssertNotEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)

    // File says DISABLING, Keychain still says ON.
    try egressJSON([(ownerA, "DISABLING", 4)]).write(to: egressFileURL)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    XCTAssertEqual(try egressState(ownerA), .record(rec("DISABLING", 4)))

    // Keychain says OFF, file says ON (crash between the two writes).
    try egressJSON([(ownerA, "ON", 3)]).write(to: egressFileURL)
    let off = try egressJSON([(ownerA, "OFF", 4)])
    SharedCaptureStore.egressKeychainReadOverride = { (errSecSuccess, off) }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)

    // File absent, Keychain DISABLING: the single marker still denies.
    try? FileManager.default.removeItem(at: egressFileURL)
    let disabling = try egressJSON([(ownerA, "DISABLING", 4)])
    SharedCaptureStore.egressKeychainReadOverride = { (errSecSuccess, disabling) }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)

    // Two ON entries that disagree (generation) for the owner: conflicting => denied.
    try egressJSON([(ownerA, "ON", 5)]).write(to: egressFileURL)
    let staleOn = try egressJSON([(ownerA, "ON", 3)])
    SharedCaptureStore.egressKeychainReadOverride = { (errSecSuccess, staleOn) }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
  }

  // C.5: per-owner records. B's restrictive write leaves A's DISABLING intact,
  // A's relaunch (a fresh read of both stores) still sees it, and A's entry
  // neither denies nor allows B.
  func testOtherOwnersWriteNeverDiscardsDisablingMarker() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try SharedCaptureStore.setCloudEgressState(
      state: "DISABLING", ownerUid: ownerA, transitionGeneration: 7, reservedVersion: 8)
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerB, transitionGeneration: 1, reservedVersion: 2)
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerB, transitionGeneration: 2, reservedVersion: 3)
    XCTAssertEqual(try egressState(ownerA), .record(rec("DISABLING", 7)),
                   "B's writes never touch A's entry")
    XCTAssertEqual(try egressState(ownerB), .record(rec("ON", 2)))

    // A's relaunch: each store alone still carries A's marker.
    let fileData = try Data(contentsOf: egressFileURL)
    SharedCaptureStore.egressKeychainReadOverride = { (errSecItemNotFound, nil) }
    XCTAssertEqual(try egressState(ownerA), .record(rec("DISABLING", 7)), "file alone")
    try FileManager.default.removeItem(at: egressFileURL)
    SharedCaptureStore.egressKeychainReadOverride = { (errSecSuccess, fileData) }
    XCTAssertEqual(try egressState(ownerA), .record(rec("DISABLING", 7)), "Keychain alone")

    // The stored keys are uidHash, never the raw uid.
    let text = String(data: fileData, encoding: .utf8) ?? ""
    XCTAssertFalse(text.contains(ownerA))
    XCTAssertTrue(text.contains(try SharedCaptureStore.debugOwnerHash(ownerA)))
  }

  // C.5: A's OFF entry does not deny B, B's own entry does.
  func testOtherOwnersOffRecordDoesNotDenyActiveOwner() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 4, reservedVersion: 5)
    let b = try publish(ownerB, cloud: true, ai: false)
    guard case .enqueued(let item) = put("B 2.00 SAR") else { return XCTFail("enqueue") }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)),
                   .allowed(ownerUid: ownerB, ownerGeneration: b.generation, allowAi: false))
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerB, transitionGeneration: 1, reservedVersion: 2)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)), .localOnly)
    XCTAssertEqual(try egressState(ownerA), .record(rec("OFF", 4)))
  }

  // D7: an extension / background intent attempt during DISABLING and after OFF
  // makes no request: the admission gate the client runs immediately before
  // URLSession returns .localOnly and registers nothing in flight.
  func testDisablingAndOffAdmitNoNativeUpload() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, a) = try stampedAllowedItem()
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 1, reservedVersion: 2)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: true))

    try SharedCaptureStore.setCloudEgressState(
      state: "DISABLING", ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 3)
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly, "DISABLING")
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 0)
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest(), "no APNs registration")

    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 3)
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly, "OFF")
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 0)
    // The persistent gate survives a sign-out wipe of the queue and owner.
    SharedCaptureStore.purgeUserOwnedState()
    XCTAssertEqual(try egressState(ownerA), .record(rec("OFF", 2)))

    // A widening write is refused while denied, a restrictive one is not.
    XCTAssertFalse(SharedCaptureStore.setBackendConfig(
      cloudProcessingEnabled: true, installID: "i", deviceSecret: "s",
      backendURL: "https://example.test", anonKey: "k", aiConsentGranted: false,
      ownerUid: ownerA, transitionGeneration: 2))
    XCTAssertTrue(SharedCaptureStore.setBackendConfig(
      cloudProcessingEnabled: false, installID: "i", deviceSecret: "s",
      backendURL: "https://example.test", anonKey: "k", aiConsentGranted: false,
      ownerUid: ownerA, transitionGeneration: 2))
    XCTAssertThrowsError(try SharedCaptureStore.setConsentMirror(
      uid: ownerA, cloud: true, ai: true, version: 9, transitionGeneration: 2)) { error in
      guard case SharedCaptureStore.QueueError.egressDenied = error else {
        return XCTFail("expected egressDenied, got \(error)")
      }
    }
    try SharedCaptureStore.setConsentMirror(
      uid: ownerA, cloud: false, ai: false, version: 9, transitionGeneration: 2)

    // Explicit enable: strictly greater generation, then egress is admitted again.
    XCTAssertThrowsError(try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 4))
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 3, reservedVersion: 4)
    XCTAssertEqual(try egressState(ownerA), .record(rec("ON", 3)))
  }

  // C.4: the durable in-flight registry. Admission registers
  // {payloadId, ownerHash, deadline = admitted_at + 8 s + 2 s}; removal clears it;
  // an entry past its deadline counts as finished.
  func testInflightRegistryRegistrationRemovalAndDeadline() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var now = base
    SharedCaptureStore.clockOverride = { now }
    let (id, a) = try stampedAllowedItem()
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 0)

    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: true))
    var live = try SharedCaptureStore.inflightUploads(forUid: ownerA)
    XCTAssertEqual(live.count, 1)
    XCTAssertEqual(live.latestDeadline, base.addingTimeInterval(10))
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerB).count, 0,
                   "scoped to the owner")
    // The registry never holds the raw uid.
    let raw = String(data: try Data(contentsOf: inflightFileURL), encoding: .utf8) ?? ""
    XCTAssertFalse(raw.contains(ownerA))
    XCTAssertTrue(raw.contains(id))

    // A retry of the same payload replaces its entry (one entry, new deadline).
    now = base.addingTimeInterval(3)
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: true))
    live = try SharedCaptureStore.inflightUploads(forUid: ownerA)
    XCTAssertEqual(live.count, 1)
    XCTAssertEqual(live.latestDeadline, base.addingTimeInterval(13))

    // Completion (success or error) removes it.
    SharedCaptureStore.removeInflightUpload(payloadID: id)
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 0)

    // An entry whose process died is finished once its deadline passes.
    XCTAssertNotEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly)
    now = base.addingTimeInterval(3 + 9.9)
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 1)
    now = base.addingTimeInterval(3 + 10.1)
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 0)

    // An unreadable registry is "unavailable" to the reader and denies admission.
    now = Date()  // real time: the corrupt file is fresh, so it is not yet replaceable
    try Data([0x00, 0xFF]).write(to: inflightFileURL)
    XCTAssertThrowsError(try SharedCaptureStore.inflightUploads(forUid: ownerA))
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly)
  }

  // D3 (native writes): a stale-generation mirror / config / publish / egress
  // write is refused and changes nothing.
  func testStaleGenerationNativeWritesAreRefused() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA, cloud: true, ai: false)
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 5, reservedVersion: 6)

    XCTAssertThrowsError(try SharedCaptureStore.setConsentMirror(
      uid: ownerA, cloud: false, ai: false, version: 9, transitionGeneration: 4)) { error in
      guard case SharedCaptureStore.QueueError.staleGeneration = error else {
        return XCTFail("expected staleGeneration, got \(error)")
      }
    }
    guard case .enqueued(let item) = put("stale 1.00 SAR") else { return XCTFail("enqueue") }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: false),
                   "the refused stale mirror write changed nothing")

    XCTAssertThrowsError(try SharedCaptureStore.publishActiveOwner(
      uid: ownerA,
      mirror: SharedCaptureStore.ConsentMirrorValue(cloud: false, ai: false, version: 9),
      expectedEpoch: try SharedCaptureStore.ownerEpoch(),
      transitionGeneration: 4))

    SharedCaptureStore.setBackendConfig(
      cloudProcessingEnabled: true, installID: "keep", deviceSecret: "s",
      backendURL: "https://example.test", anonKey: "k", aiConsentGranted: false)
    XCTAssertFalse(SharedCaptureStore.setBackendConfig(
      cloudProcessingEnabled: false, installID: "stale", deviceSecret: nil,
      backendURL: nil, anonKey: nil, aiConsentGranted: false,
      ownerUid: ownerA, transitionGeneration: 4))
    XCTAssertEqual(SharedCaptureStore.backendConfig().installID, "keep")
    XCTAssertTrue(SharedCaptureStore.backendConfig().cloudProcessingEnabled)

    XCTAssertThrowsError(try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 4, reservedVersion: 5)) { error in
      guard case SharedCaptureStore.QueueError.staleGeneration = error else {
        return XCTFail("expected staleGeneration, got \(error)")
      }
    }
    // A new owner starts fresh: B at generation 1 is not stale against A's 5.
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerB, transitionGeneration: 1, reservedVersion: 2)
  }

  // P6: a restrictive mirror (cloud=false, ai=false) is published atomically with
  // the owner under the flock; the capture is local-only, never uploaded. A
  // publish with no authority (stale epoch / barrier) writes nothing.
  func testRestrictivePublishIsAtomicAndRefusedWithoutAuthority() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let epoch = try SharedCaptureStore.ownerEpoch()
    let a = try SharedCaptureStore.publishActiveOwner(
      uid: ownerA,
      mirror: SharedCaptureStore.ConsentMirrorValue(cloud: false, ai: false, version: 1),
      expectedEpoch: epoch)
    XCTAssertEqual(try SharedCaptureStore.activeOwner(), a)
    guard case .enqueued(let item) = put("restrictive 1.00 SAR") else { return XCTFail("enqueue") }
    XCTAssertEqual(item.localOnly, true)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)), .localOnly)

    try SharedCaptureStore.clearActiveOwner(clearHint: true)
    XCTAssertThrowsError(try SharedCaptureStore.publishActiveOwner(
      uid: ownerB,
      mirror: SharedCaptureStore.ConsentMirrorValue(cloud: false, ai: false, version: 1),
      expectedEpoch: epoch))
    XCTAssertNil(try SharedCaptureStore.activeOwner())
    let currentEpoch = try SharedCaptureStore.ownerEpoch()
    SharedCaptureStore.lockUnavailableOverride = true
    XCTAssertThrowsError(try SharedCaptureStore.publishActiveOwner(
      uid: ownerB,
      mirror: SharedCaptureStore.ConsentMirrorValue(cloud: false, ai: false, version: 1),
      expectedEpoch: currentEpoch), "uncertain authority (no flock) must refuse")
  }

  // C.1 + C.4 source pins for the one native network client: ownerless is
  // impossible, owner_uid/owner_generation go on EVERY schema version, and the
  // admission re-check sits between building the body and URLSession.
  func testBackendClientOwnerBindingAndAdmissionOrder() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("BankMessageShortcuts/BankMessageShortcuts.swift"))
    XCTAssertFalse(source.contains("ownerUid: String? = nil"), "an ownerless upload must not compile")
    let ownerBody = try XCTUnwrap(source.range(of: "body[\"owner_uid\"] = ownerUid"))
    let schema = try XCTUnwrap(source.range(of: "body[\"schema_version\"] = 2"))
    XCTAssertLessThan(ownerBody.lowerBound, schema.lowerBound,
                      "owner_uid is not inside the schema_version 2 branch")
    XCTAssertTrue(source.contains("body[\"owner_generation\"] = ownerGeneration"))
    let gate = try XCTUnwrap(source.range(of: "admittedUid == ownerUid"))
    XCTAssertTrue(source.contains("SharedCaptureStore.admitUpload(payloadID: payloadID)"))
    XCTAssertTrue(source.contains("defer { SharedCaptureStore.removeInflightUpload(payloadID: payloadID) }"))
    let network = try XCTUnwrap(source.range(of: "URLSession.shared.data(for: urlRequest)"))
    XCTAssertLessThan(gate.lowerBound, network.lowerBound)
    XCTAssertEqual(source.components(separatedBy: "URLSession.shared").count - 1, 1,
                   "exactly one native network call site")
  }
}
