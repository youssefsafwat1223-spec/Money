import AppIntents
import Flutter
import UIKit
import UserNotifications

/// The APNs host a device token belongs to, derived from the entitlement this
/// binary was ACTUALLY SIGNED WITH.
///
/// WHY NOT `#if DEBUG`.
/// It used to be `#if DEBUG ? "sandbox" : "production"`. `DEBUG` is not defined
/// in this project's Swift build conditions — `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
/// is unset on Debug, Profile AND Release — so the branch was dead and every
/// build reported "production". A real iPhone proved it: a Debug build signed
/// `aps-environment: development` registered a SANDBOX token as `production`,
/// which routes `sendCapturePush` to api.push.apple.com and earns BadDeviceToken
/// on every send. Configuration names, Flutter build mode and compile flags all
/// describe INTENT; only the signed entitlement describes what Apple actually
/// issued the token for.
///
/// `SecTaskCopyValueForEntitlement` is the natural API but `SecTask` is not in
/// the public iOS SDK (no `SecTask.h` under the iPhoneOS SDK's Security
/// framework), so the App-Store-safe equivalent is the embedded provisioning
/// profile, which is the artefact that GRANTED the entitlement.
enum ApnsEnvironment {
  static let entitlementKey = "aps-environment"

  /// Pure mapping seam — the only place the vocabulary is translated.
  /// `nil` means UNRESOLVED, and callers must withhold the token.
  static func map(entitlement: String?) -> String? {
    switch entitlement {
    case "development": return "sandbox"
    case "production": return "production"
    default: return nil
    }
  }

  /// Pull `aps-environment` out of a provisioning profile's CMS blob.
  /// The payload is a plist embedded in DER, so the plist range is sliced out
  /// rather than the whole blob being parsed.
  static func entitlement(inProfile data: Data) -> String? {
    guard let raw = String(data: data, encoding: .isoLatin1),
          let start = raw.range(of: "<plist"),
          let end = raw.range(of: "</plist>"),
          let plistData = String(raw[start.lowerBound..<end.upperBound])
            .data(using: .isoLatin1),
          let plist = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil) as? [String: Any],
          let entitlements = plist["Entitlements"] as? [String: Any]
    else { return nil }
    return entitlements[entitlementKey] as? String
  }

  /// Positive evidence that this binary came from the App Store or TestFlight.
  ///
  /// Those are the only distribution channels that legitimately ship WITHOUT an
  /// embedded provisioning profile — Apple strips it and re-signs for the
  /// production APNs environment. The receipt is the artefact that proves it:
  /// `receipt` for the App Store, `sandboxReceipt` for TestFlight (which is a
  /// StoreKit sandbox, unrelated to the APNs sandbox — a TestFlight build's
  /// pushes go to the PRODUCTION host). A development build has no receipt, so
  /// "no profile" alone can never be mistaken for "shipped by Apple".
  static func isStoreDistributed(bundle: Bundle = .main) -> Bool {
    guard let url = bundle.appStoreReceiptURL else { return false }
    let name = url.lastPathComponent
    guard name == "receipt" || name == "sandboxReceipt" else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  /// Pure resolution seam — both missing-profile branches are testable.
  ///
  /// `nil` means UNRESOLVED and the caller must withhold the token.
  static func resolve(profileData: Data?, isStoreDistributed: Bool) -> String? {
    guard let data = profileData else {
      // No profile. Only a real store receipt justifies "production"; anything
      // else (a stripped, corrupted or hand-assembled bundle) fails closed.
      return isStoreDistributed ? "production" : nil
    }
    return map(entitlement: entitlement(inProfile: data))
  }

  /// The environment this PROCESS was signed for, or `nil` when it cannot be
  /// established — in which case no token may be registered.
  ///
  /// Nothing here reads a configuration NAME or a compile flag. The inputs are
  /// the signed provisioning profile and the store receipt, both of which are
  /// artefacts of how the binary was actually distributed.
  static func current(bundle: Bundle = .main) -> String? {
    if let url = bundle.url(
      forResource: "embedded", withExtension: "mobileprovision") {
      // A profile that exists but cannot be READ is unresolved — never treated
      // as "absent", which would fall through to the store-receipt branch.
      guard let data = try? Data(contentsOf: url) else { return nil }
      return resolve(profileData: data, isStoreDistributed: false)
    }
    return resolve(
      profileData: nil, isStoreDistributed: isStoreDistributed(bundle: bundle))
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var captureChannel: FlutterMethodChannel?
  private var exportProtectionChannel: FlutterMethodChannel?
  private var nativeGlassChannel: FlutterMethodChannel?
  private var didRegisterPendingMessagesObserver = false
  private var privacySnapshotView: UIView?
  private static let apnsRegistrationFailureKey = "apns_registration_failure"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "NativeGlass") {
      registrar.register(
        NativeGlassViewFactory(),
        withId: "mali_glass_native"
      )
    }
    let didFinish = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    configureNativeCaptureChannelIfNeeded()
    configureExportProtectionChannelIfNeeded()
    configureNativeGlassChannelIfNeeded()
    if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
      SharedCaptureStore.enqueueNotificationRoute(userInfo: remote)
    }
    BankMessageShortcuts.updateAppShortcutParameters()
    return didFinish
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    removePrivacySnapshotView()
    configureNativeCaptureChannelIfNeeded()
    configureExportProtectionChannelIfNeeded()
    configureNativeGlassChannelIfNeeded()
  }

  /// Answers the one question Dart needs before building glass surfaces:
  /// does this device have the real iOS 26 Liquid Glass material?
  func configureNativeGlassChannelIfNeeded() {
    guard nativeGlassChannel == nil,
          let controller = rootFlutterViewController() else {
      return
    }

    let channel = FlutterMethodChannel(
      name: "mali/native_glass",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isSupported":
        result(NativeGlass.isSupported)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    nativeGlassChannel = channel
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    installPrivacySnapshotView()
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    super.applicationWillEnterForeground(application)
    removePrivacySnapshotView()
  }

  func configureNativeCaptureChannelIfNeeded() {
    guard captureChannel == nil, let controller = rootFlutterViewController() else {
      return
    }

    let channel = FlutterMethodChannel(
      name: "money_companion/native_capture",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "consumePendingSharedInput":
        result(SharedCaptureStore.consumePendingText())
      case "consumePendingSharedMessages":
        result(SharedCaptureStore.consumePendingPayloadsJSON())
      case "peekPendingSharedMessages":
        // Per-item lease (MALI-012): returns the queue without deleting it;
        // Dart acks each payload after its import commits.
        result(SharedCaptureStore.peekPendingPayloadsJSON())
      case "acknowledgeSharedMessage":
        let payloadId =
          (call.arguments as? [String: Any])?["payloadId"] as? String
        if let payloadId = payloadId {
          result(SharedCaptureStore.remove(payloadID: payloadId))
        } else {
          result(false)
        }
      case "hasPendingSharedMessages":
        result(SharedCaptureStore.hasPendingMessages())
      // COUPONS Phase 5 — shared merchant links.
      //
      // A SEPARATE method reading a SEPARATE store. One method returning a
      // mixed list would put a shopping URL one missed branch away from the SMS
      // parser, which is precisely what the two-store split exists to prevent.
      case "drainOfferIntents":
        result(SharedOfferIntentStore.drain())
      case "setCaptureBackendConfig":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(
            code: "bad_args",
            message: "Expected backend config arguments.",
            details: nil
          ))
          return
        }
        SharedCaptureStore.setBackendConfig(
          cloudProcessingEnabled: args["cloudProcessingEnabled"] as? Bool ?? false,
          installID: args["installId"] as? String,
          deviceSecret: args["deviceSecret"] as? String,
          backendURL: args["backendUrl"] as? String,
          anonKey: args["anonKey"] as? String,
          aiConsentGranted: args["aiConsentGranted"] as? Bool ?? false
        )
        result(nil)
      case "registerForRemoteNotifications":
        UIApplication.shared.registerForRemoteNotifications()
        if let info = SharedCaptureStore.apnsTokenInfo() {
          result([
            "token": info.token,
            "environment": info.environment,
          ])
        } else {
          result(nil)
        }
      case "getApnsToken":
        if let info = SharedCaptureStore.apnsTokenInfo() {
          result([
            "token": info.token,
            "environment": info.environment,
          ])
        } else {
          result(nil)
        }
      case "getApnsRegistrationFailure":
        result(UserDefaults.standard.dictionary(
          forKey: AppDelegate.apnsRegistrationFailureKey
        ))
      case "consumePendingNotificationRoutes":
        result(SharedCaptureStore.consumePendingNotificationRoutesJSON())
      case "consumePendingNotificationLogEvents":
        result(SharedCaptureStore.consumePendingNotificationLogEventsJSON())
      case "reEnqueueSharedMessage":
        // Puts a drained message back after Flutter failed to process it —
        // the queue drain is destructive, so without this a single failing
        // message would silently lose the capture. notifyHost=false: waking
        // the host again immediately would loop drain → fail → re-enqueue.
        guard let args = call.arguments as? [String: Any],
              let text = args["text"] as? String, !text.isEmpty else {
          result(FlutterError(
            code: "bad_args",
            message: "Expected the original shared message fields.",
            details: nil
          ))
          return
        }
        let receivedAt = (args["receivedAt"] as? String)
          .flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let status = SharedCaptureStore.CaptureStatus(
          rawValue: args["status"] as? String ?? ""
        ) ?? .pending
        let outcome = SharedCaptureStore.enqueue(
          text: text,
          sender: args["sender"] as? String,
          senderName: args["senderName"] as? String,
          senderID: args["senderId"] as? String,
          source: args["source"] as? String,
          receivedAt: receivedAt,
          localeIdentifier: args["locale"] as? String,
          status: status,
          failureReason: args["failureReason"] as? String,
          payloadID: args["payloadId"] as? String,
          notifyHost: false
        )
        if case let .failed(reason) = outcome {
          result(FlutterError(code: "reenqueue_failed", message: reason, details: nil))
        } else {
          result(nil)
        }
      case "hasSmsPermission":
        result(false)
      case "openAppSettings":
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
        result(nil)
      case "purgeAllCaptureState":
        // MALI-054n: wipe this identity's capture residue from the App Group.
        result(SharedCaptureStore.purgeUserOwnedState())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    captureChannel = channel
    registerPendingMessagesObserverIfNeeded()
  }

  /// MALI-065n — applies at-rest protection to a managed export temp file:
  /// NSFileProtectionComplete (unreadable while the device is locked) and
  /// exclusion from iCloud/iTunes backup. Best-effort from Dart's side.
  func configureExportProtectionChannelIfNeeded() {
    guard exportProtectionChannel == nil,
          let controller = rootFlutterViewController() else {
      return
    }

    let channel = FlutterMethodChannel(
      name: "mali/export_protection",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "protect":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(
            code: "bad_args",
            message: "Expected a file path.",
            details: nil
          ))
          return
        }
        do {
          try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: path
          )
          var url = URL(fileURLWithPath: path)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try url.setResourceValues(values)
          result(nil)
        } catch {
          result(FlutterError(
            code: "protect_failed",
            message: error.localizedDescription,
            details: nil
          ))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    exportProtectionChannel = channel
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    // Fail closed. A token registered against the wrong host is worse than no
    // token: the backend reports a healthy send and nothing is ever delivered.
    guard let environment = ApnsEnvironment.current() else {
      let failure: [String: Any] = [
        "message":
          "aps-environment entitlement missing or unrecognised; push token withheld",
        "domain": "qirsh.apns.environment",
        "code": -1,
        "occurredAt": ISO8601DateFormatter().string(from: Date()),
      ]
      UserDefaults.standard.set(failure, forKey: AppDelegate.apnsRegistrationFailureKey)
      captureChannel?.invokeMethod("apnsRegistrationFailed", arguments: failure)
      // Diagnostic only: no token, no entitlement value, no identifiers.
      NSLog("[Capture] APNs environment unresolved - token not registered")
      return
    }
    SharedCaptureStore.setApnsToken(token, environment: environment)
    UserDefaults.standard.removeObject(forKey: AppDelegate.apnsRegistrationFailureKey)
    captureChannel?.invokeMethod("apnsTokenUpdated", arguments: [
      "token": token,
      "environment": environment,
    ])
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    let nsError = error as NSError
    let failure: [String: Any] = [
      "message": error.localizedDescription,
      "domain": nsError.domain,
      "code": nsError.code,
      "occurredAt": ISO8601DateFormatter().string(from: Date()),
    ]
    UserDefaults.standard.set(failure, forKey: AppDelegate.apnsRegistrationFailureKey)
    captureChannel?.invokeMethod("apnsRegistrationFailed", arguments: failure)
    #if DEBUG
    print("[Capture] APNs registration failed: \(error)")
    #endif
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    if userInfo["source"] as? String == "ios_shortcut" ||
      userInfo["payloadId"] as? String != nil {
      SharedCaptureStore.enqueueNotificationRoute(userInfo: userInfo)
      captureChannel?.invokeMethod("pendingNotificationRouteAvailable", arguments: nil)
      completionHandler()
      return
    }
    super.userNotificationCenter(
      center,
      didReceive: response,
      withCompletionHandler: completionHandler
    )
  }

  private func registerPendingMessagesObserverIfNeeded() {
    guard !didRegisterPendingMessagesObserver else { return }
    didRegisterPendingMessagesObserver = true
    let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      observer,
      { _, observer, _, _, _ in
        guard let observer else { return }
        let appDelegate = Unmanaged<AppDelegate>
          .fromOpaque(observer)
          .takeUnretainedValue()
        DispatchQueue.main.async {
          appDelegate.captureChannel?.invokeMethod(
            "pendingSharedMessagesAvailable",
            arguments: nil
          )
        }
      },
      SharedCaptureStore.pendingMessagesNotificationName as CFString,
      nil,
      .deliverImmediately
    )
  }

  private func rootFlutterViewController() -> FlutterViewController? {
    if let controller = window?.rootViewController as? FlutterViewController {
      return controller
    }

    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      if let controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController as? FlutterViewController {
        return controller
      }
    }

    return nil
  }

  private func installPrivacySnapshotView() {
    guard privacySnapshotView == nil, let targetWindow = window else { return }
    let overlay = UIView(frame: targetWindow.bounds)
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlay.backgroundColor = UIColor.systemBackground

    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "قرش"
    label.font = UIFont.systemFont(ofSize: 28, weight: .bold)
    label.textColor = UIColor.label
    overlay.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
    ])

    targetWindow.addSubview(overlay)
    targetWindow.bringSubviewToFront(overlay)
    privacySnapshotView = overlay
  }

  private func removePrivacySnapshotView() {
    privacySnapshotView?.removeFromSuperview()
    privacySnapshotView = nil
  }
}
