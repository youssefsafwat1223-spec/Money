import Flutter
import UIKit

/// Real Apple Liquid Glass (iOS 26 `UIGlassEffect`) exposed to Flutter as a
/// platform view, following callstack/liquid-glass: runtime-guarded class +
/// selector checks so early-beta SDKs degrade safely. Below iOS 26 the view
/// renders a system thin material blur instead; Dart additionally gates on
/// `isSupported` so unsupported devices never create this view at all.
enum NativeGlass {
  static var isSupported: Bool {
    #if compiler(>=6.2)
    guard #available(iOS 26.0, *) else { return false }
    guard let cls = NSClassFromString("UIGlassEffect") as? NSObject.Type else {
      return false
    }
    return cls.responds(to: Selector(("effectWithStyle:")))
    #else
    return false
    #endif
  }
}

final class NativeGlassViewFactory: NSObject, FlutterPlatformViewFactory {
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    NativeGlassPlatformView(frame: frame, args: args as? [String: Any])
  }
}

/// UIVisualEffectView whose corner radius re-clamps on every layout — Flutter
/// sends the design radius (pill = 999) and UIKit needs it capped at half the
/// short side to stay circular instead of glitching.
private final class GlassEffectView: UIVisualEffectView {
  var requestedRadius: CGFloat = 0

  override func layoutSubviews() {
    super.layoutSubviews()
    let cap = min(bounds.width, bounds.height) / 2
    layer.cornerRadius = min(requestedRadius, max(cap, 0))
  }
}

final class NativeGlassPlatformView: NSObject, FlutterPlatformView {
  private let effectView: GlassEffectView

  init(frame: CGRect, args: [String: Any]?) {
    effectView = GlassEffectView(frame: frame)
    super.init()

    effectView.requestedRadius =
      CGFloat((args?["radius"] as? NSNumber)?.doubleValue ?? 0)
    effectView.layer.cornerCurve = .continuous
    effectView.clipsToBounds = true
    // Touches belong to the Flutter content above; the Dart side owns the
    // press affordances (scale + glow), so the native layer stays passive.
    effectView.isUserInteractionEnabled = false

    // Keep the material in the app's theme even when it diverges from the
    // system theme (in-app theme setting / gallery toggle).
    if let dark = (args?["dark"] as? NSNumber)?.boolValue {
      effectView.overrideUserInterfaceStyle = dark ? .dark : .light
    }

    let clear = (args?["clear"] as? NSNumber)?.boolValue ?? false
    effectView.effect = Self.makeEffect(clear: clear)
  }

  private static func makeEffect(clear: Bool) -> UIVisualEffect {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *), NativeGlass.isSupported {
      let effect = UIGlassEffect(style: clear ? .clear : .regular)
      // Apple's interactive shimmer needs native touches, which never reach
      // this view (Flutter content sits above) — leave it off.
      effect.isInteractive = false
      return effect
    }
    #endif
    return UIBlurEffect(style: .systemUltraThinMaterial)
  }

  func view() -> UIView { effectView }
}
