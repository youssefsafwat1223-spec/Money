import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private static let foregroundKey = "app_is_foreground"

  /// Registers the native capture channel at the EARLIEST deterministic point.
  ///
  /// Under the UIScene lifecycle `didFinishLaunchingWithOptions` runs before any
  /// scene connects, so `rootFlutterViewController()` is nil there and the
  /// registration in AppDelegate silently no-ops. Until now the next opportunity
  /// was `applicationDidBecomeActive` / `sceneDidBecomeActive` — both of which
  /// fire AFTER the engine has started running Dart. Dart bootstrap calls
  /// `purgeAllCaptureState` inside that window and got MissingPluginException;
  /// with the old ownership ordering that cost users their data (ac622970).
  ///
  /// `scene(_:willConnectTo:)` is where Flutter builds the window from
  /// Main.storyboard, whose root view controller IS the FlutterViewController.
  /// After `super` its binaryMessenger exists, so the handler is installed
  /// before Dart can reach the channel — and messages are queued by the engine
  /// regardless, so even a very early Dart call is answered rather than dropped.
  ///
  /// Deliberately NOT dependent on the scene being foreground-active: a scene
  /// that connects while still inactive (state restoration, a background
  /// launch) registers here just the same.
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      // Both are idempotent against the CURRENT FlutterViewController, so the
      // later lifecycle call sites remain defence in depth without ever
      // installing a second handler — and a scene reconnect, which builds a NEW
      // controller, correctly rebinds instead of returning early.
      appDelegate.configureNativeCaptureChannelIfNeeded()
      // Same window, same reasoning: Dart asks for the device zone during
      // bootstrap (notifications_init), before the first frame.
      appDelegate.configureDeviceTimezoneChannelIfNeeded()
    }
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    UserDefaults(suiteName: SharedCaptureStore.appGroupIdentifier)?
      .set(true, forKey: Self.foregroundKey)
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      appDelegate.configureNativeCaptureChannelIfNeeded()
      appDelegate.configureDeviceTimezoneChannelIfNeeded()
    }
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    UserDefaults(suiteName: SharedCaptureStore.appGroupIdentifier)?
      .set(false, forKey: Self.foregroundKey)
  }
}
