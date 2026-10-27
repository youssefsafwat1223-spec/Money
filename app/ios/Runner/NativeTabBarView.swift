import Flutter
import UIKit

/// Apple's own tab bar (`UITabBar`) as a Flutter platform view, so iOS 26+
/// draws it with the system Liquid Glass material, lensing and selection
/// morph exactly like every native app. Flutter keeps the routing: a tap is
/// reported over `mali/native_tab_bar_<id>` and Flutter decides the page.
final class NativeTabBarViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    NativeTabBarPlatformView(
      frame: frame,
      viewId: viewId,
      args: args as? [String: Any] ?? [:],
      messenger: messenger
    )
  }
}

final class NativeTabBarPlatformView: NSObject, FlutterPlatformView, UITabBarDelegate {
  private let container: UIView
  private let tabBar = UITabBar()
  private let channel: FlutterMethodChannel

  init(
    frame: CGRect,
    viewId: Int64,
    args: [String: Any],
    messenger: FlutterBinaryMessenger
  ) {
    container = UIView(frame: frame)
    channel = FlutterMethodChannel(
      name: "mali/native_tab_bar_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    container.backgroundColor = .clear
    tabBar.translatesAutoresizingMaskIntoConstraints = false
    tabBar.delegate = self
    container.addSubview(tabBar)
    NSLayoutConstraint.activate([
      tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      tabBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      tabBar.topAnchor.constraint(equalTo: container.topAnchor),
    ])

    let items = (args["items"] as? [[String: Any]]) ?? []
    tabBar.items = items.enumerated().map { index, item in
      let symbol = item["symbol"] as? String ?? "circle"
      let tabItem = UITabBarItem(
        title: item["title"] as? String,
        image: UIImage(systemName: symbol),
        selectedImage: UIImage(systemName: "\(symbol).fill")
          ?? UIImage(systemName: symbol)
      )
      tabItem.tag = index
      return tabItem
    }
    apply(args)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      if call.method == "update", let update = call.arguments as? [String: Any] {
        self.apply(update)
      }
      result(nil)
    }
  }

  private func apply(_ args: [String: Any]) {
    if let selected = (args["selected"] as? NSNumber)?.intValue,
       let items = tabBar.items, selected >= 0, selected < items.count {
      tabBar.selectedItem = items[selected]
    }
    if let dark = (args["dark"] as? NSNumber)?.boolValue {
      container.overrideUserInterfaceStyle = dark ? .dark : .light
    }
    if let rtl = (args["rtl"] as? NSNumber)?.boolValue {
      let attribute: UISemanticContentAttribute =
        rtl ? .forceRightToLeft : .forceLeftToRight
      container.semanticContentAttribute = attribute
      tabBar.semanticContentAttribute = attribute
    }
    if let tint = (args["tint"] as? NSNumber)?.uint32Value {
      tabBar.tintColor = UIColor(
        red: CGFloat((tint >> 16) & 0xFF) / 255,
        green: CGFloat((tint >> 8) & 0xFF) / 255,
        blue: CGFloat(tint & 0xFF) / 255,
        alpha: CGFloat((tint >> 24) & 0xFF) / 255
      )
    }
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    channel.invokeMethod("select", arguments: item.tag)
  }

  func view() -> UIView { container }
}
