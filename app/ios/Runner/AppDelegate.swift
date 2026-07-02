import AppIntents
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var captureChannel: FlutterMethodChannel?
  private var didRegisterPendingMessagesObserver = false

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
    configureNativeCaptureChannelIfNeeded()
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
      case "consumePendingNotificationRoutes":
        result(SharedCaptureStore.consumePendingNotificationRoutesJSON())
      case "hasSmsPermission":
        result(false)
      case "openAppSettings":
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
        result(nil)
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
    captureChannel?.invokeMethod("apnsTokenUpdated", arguments: [
      "token": token,
      "environment": environment,
    ])
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
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
}
