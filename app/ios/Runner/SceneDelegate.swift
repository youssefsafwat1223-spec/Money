import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private static let foregroundKey = "app_is_foreground"

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    UserDefaults(suiteName: SharedCaptureStore.appGroupIdentifier)?
      .set(true, forKey: Self.foregroundKey)
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      appDelegate.configureNativeCaptureChannelIfNeeded()
    }
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    UserDefaults(suiteName: SharedCaptureStore.appGroupIdentifier)?
      .set(false, forKey: Self.foregroundKey)
  }
}
