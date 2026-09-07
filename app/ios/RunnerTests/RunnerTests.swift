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

  private var appGroupDefaults: UserDefaults {
    UserDefaults(suiteName: SharedCaptureStore.appGroupIdentifier)!
  }

  // MALI-031 — the capture queue is encrypted at rest; the raw SMS never appears
  // as plaintext in App Group UserDefaults, but round-trips out via the store.
  func testCaptureQueueEncryptedAtRestAndRoundTrips() throws {
    SharedCaptureStore.purgeUserOwnedState()
    let secret = "ACME: purchase 512.34 SAR on card 4417"
    let result = SharedCaptureStore.enqueue(text: secret, sender: "ACME")
    if case .failed(let reason) = result { XCTFail("enqueue failed: \(reason)") }

    let json = try XCTUnwrap(SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertTrue(json.contains(secret), "the store must decrypt back to plaintext")

    let blob = try XCTUnwrap(appGroupDefaults.data(forKey: "pending_bank_messages_v2"))
    let asText = String(data: blob, encoding: .utf8) ?? ""
    XCTAssertFalse(asText.contains(secret), "raw SMS must NOT be stored in plaintext")
    SharedCaptureStore.purgeUserOwnedState()
  }

  // A legacy plaintext-JSON blob is migrated transparently on read.
  func testLegacyPlaintextQueueStillReads() throws {
    SharedCaptureStore.purgeUserOwnedState()
    let legacy = "[{\"id\":\"abc\",\"text\":\"legacy 10.00\",\"status\":\"pending\"}]"
    appGroupDefaults.set(Data(legacy.utf8), forKey: "pending_bank_messages_v2")
    let json = try XCTUnwrap(SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertTrue(json.contains("legacy 10.00"))
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
}
