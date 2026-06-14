import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      appDelegate.configureNativeCaptureChannelIfNeeded()
    }
  }
}
