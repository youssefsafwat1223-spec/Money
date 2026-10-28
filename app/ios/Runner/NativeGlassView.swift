import Flutter
import UIKit

/// Real Apple Liquid Glass (iOS 26 `UIGlassEffect`) exposed to Flutter as a
/// platform view. Below iOS 26 the view renders a system thin material blur
/// instead; Dart additionally gates on `isSupported` so unsupported devices
/// never create this view at all.
///
/// The material is left to the system: `.regular` style, no custom opacity or
/// blur, so the user's Liquid Glass look (Settings > Display & Brightness),
/// Reduce Transparency and Increase Contrast all apply automatically. The
/// only inputs are the app's light/dark choice and an optional semantic
/// `tintColor`.
enum NativeGlass {
  static var isSupported: Bool {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) { return true }
    #endif
    return false
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
    let clamped = min(requestedRadius, max(cap, 0))
    layer.cornerRadius = clamped
    // iOS 26: the glass material's own rim follows `cornerConfiguration`,
    // not `layer.cornerRadius` — without this the rim renders as an ugly
    // rectangular frame around rounded surfaces.
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      cornerConfiguration = requestedRadius >= cap
        ? .capsule()
        : .corners(radius: .fixed(clamped))
    }
    #endif
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
    // system theme (in-app theme setting / gallery toggle). Creation-time:
    // Dart keys the view on `dark`, so a theme switch rebuilds it.
    if let dark = (args?["dark"] as? NSNumber)?.boolValue {
      effectView.overrideUserInterfaceStyle = dark ? .dark : .light
    }

    let clear = (args?["clear"] as? NSNumber)?.boolValue ?? false
    let tint = (args?["tint"] as? NSNumber).map { Self.color(argb: $0.uint32Value) }
    effectView.effect = Self.makeEffect(clear: clear, tint: tint)
  }

  static func makeEffect(clear: Bool, tint: UIColor?) -> UIVisualEffect {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: clear ? .clear : .regular)
      // Apple's interactive shimmer needs native touches, which never reach
      // this view (Flutter content sits above) — leave it off.
      effect.isInteractive = false
      // Semantic tint only (e.g. a status banner) — the system decides how
      // strongly it shows under the user's glass and accessibility settings.
      effect.tintColor = tint
      return effect
    }
    #endif
    return UIBlurEffect(style: .systemUltraThinMaterial)
  }

  private static func color(argb: UInt32) -> UIColor {
    UIColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255
    )
  }

  func view() -> UIView { effectView }
}
