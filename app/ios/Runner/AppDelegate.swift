import AppIntents
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var captureChannel: FlutterMethodChannel?
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
    let didFinish = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    configureNativeCaptureChannelIfNeeded()
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

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    let environment: String
    #if DEBUG
    environment = "sandbox"
    #else
    environment = "production"
    #endif
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
