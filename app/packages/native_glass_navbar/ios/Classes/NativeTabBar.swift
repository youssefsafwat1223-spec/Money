import Flutter
import UIKit

class NativeTabBarFactory: NSObject, FlutterPlatformViewFactory {
  private var messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return NativeTabBarPlatformView(
      viewId: viewId,
      args: args,
      messenger: messenger
    )
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

class NativeTabBarPlatformView: NSObject, FlutterPlatformView {
  private let controller: LiquidGlassTabBarController

  init(viewId: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
    self.controller = LiquidGlassTabBarController(
      viewId: viewId,
      messenger: messenger,
      args: args
    )
    super.init()
  }

  func view() -> UIView {
    return controller.view
  }
}

struct TabBarConfig: Equatable {
  var labels: [String] = []
  var symbols: [String] = []
  var actionButtonSymbol: String = ""
  var tintColor: UIColor = .systemBlue
  var selectedIndex: Int = 0
  var isDark: Bool = false

  init(from dict: [String: Any]?) {
    guard let dict = dict else { return }
    if let labels = dict["labels"] as? [String] { self.labels = labels }
    if let symbols = dict["symbols"] as? [String] { self.symbols = symbols }
    if let action = dict["actionButtonSymbol"] as? String {
      self.actionButtonSymbol = action
    }
    if let colorInt = dict["tintColor"] as? NSNumber {
      self.tintColor = TabBarConfig.uiColorFromARGB(colorInt.intValue)
    }
    if let selectedIndex = dict["selectedIndex"] as? Int {
      self.selectedIndex = selectedIndex
    }
    if let isDark = dict["isDark"] as? Bool {
      self.isDark = isDark
    }
  }

  func structuralChange(from other: TabBarConfig) -> Bool {
    return labels.count != other.labels.count ||
      symbols.count != other.symbols.count ||
      (actionButtonSymbol.isEmpty != other.actionButtonSymbol.isEmpty)
  }

  private static func uiColorFromARGB(_ argb: Int) -> UIColor {
    let alpha = CGFloat((argb >> 24) & 0xFF) / 255.0
    let red = CGFloat((argb >> 16) & 0xFF) / 255.0
    let green = CGFloat((argb >> 8) & 0xFF) / 255.0
    let blue = CGFloat(argb & 0xFF) / 255.0
    return UIColor(red: red, green: green, blue: blue, alpha: alpha)
  }
}

class LiquidGlassTabBarController: UITabBarController, UITabBarControllerDelegate {
  private let channel: FlutterMethodChannel
  private var config: TabBarConfig
  private var currentAppearanceIsDark: Bool

  init(viewId: Int64, messenger: FlutterBinaryMessenger, args: Any?) {
    self.channel = FlutterMethodChannel(
      name: "NativeTabBar_\(viewId)",
      binaryMessenger: messenger
    )
    self.config = TabBarConfig(from: args as? [String: Any])
    self.currentAppearanceIsDark = config.isDark
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.isOpaque = false
    delegate = self
    overrideUserInterfaceStyle = config.isDark ? .dark : .light
    configureAppearance()
    performFullRebuild()

    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    view.backgroundColor = .clear
  }

  private func configureAppearance() {
    let appearance = UITabBarAppearance()
    appearance.configureWithDefaultBackground()
    appearance.backgroundColor = .clear
    appearance.shadowColor = .clear
    appearance.backgroundEffect = UIBlurEffect(style: config.isDark ? .dark : .light)

    let itemAppearance = UITabBarItemAppearance()
    itemAppearance.normal.iconColor = .systemGray
    itemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.systemGray]
    itemAppearance.selected.iconColor = config.tintColor
    itemAppearance.selected.titleTextAttributes = [.foregroundColor: config.tintColor]

    appearance.stackedLayoutAppearance = itemAppearance
    appearance.inlineLayoutAppearance = itemAppearance
    appearance.compactInlineLayoutAppearance = itemAppearance

    tabBar.standardAppearance = appearance
    if #available(iOS 15.0, *) {
      tabBar.scrollEdgeAppearance = appearance
    }
    tabBar.isTranslucent = true
    tabBar.tintColor = config.tintColor
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "update", let dict = call.arguments as? [String: Any] {
      let newConfig = TabBarConfig(from: dict)
      let oldConfig = config

      if newConfig.structuralChange(from: oldConfig) {
        config = newConfig
        performFullRebuild()
      } else {
        config = newConfig
        updateSelectionAndColors()
        if oldConfig.actionButtonSymbol != newConfig.actionButtonSymbol {
          updateActionSymbolInPlace()
        }
      }
      result(nil)
    } else {
      result(FlutterMethodNotImplemented)
    }
  }

  private func updateActionSymbolInPlace() {
    guard let viewControllers = viewControllers else { return }
    if let actionVC = viewControllers.first(where: { $0.tabBarItem.tag == 99 }) {
      actionVC.tabBarItem.image = resolveSymbol(config.actionButtonSymbol)
    }
  }

  private func performFullRebuild() {
    var controllers: [UIViewController] = []
    let count = max(config.labels.count, config.symbols.count)

    for index in 0..<count {
      let viewController = UIViewController()
      viewController.view.backgroundColor = .clear

      let symbolName = index < config.symbols.count ? config.symbols[index] : "questionmark"
      let label = index < config.labels.count ? config.labels[index] : ""

      viewController.tabBarItem = UITabBarItem(
        title: label,
        image: resolveSymbol(symbolName),
        tag: index
      )
      controllers.append(viewController)
    }

    if !config.actionButtonSymbol.isEmpty {
      let actionVC = UIViewController()
      actionVC.view.backgroundColor = .clear
      let item = UITabBarItem(tabBarSystemItem: .search, tag: 99)
      item.image = resolveSymbol(config.actionButtonSymbol)
      actionVC.tabBarItem = item
      controllers.append(actionVC)
    }

    setViewControllers(controllers, animated: false)
    updateSelectionAndColors()
  }

  private func updateSelectionAndColors() {
    let needsAppearanceUpdate =
      tabBar.tintColor != config.tintColor ||
      currentAppearanceIsDark != config.isDark

    if needsAppearanceUpdate {
      tabBar.tintColor = config.tintColor
      currentAppearanceIsDark = config.isDark
      overrideUserInterfaceStyle = config.isDark ? .dark : .light
      configureAppearance()
    }

    if selectedIndex != config.selectedIndex,
       let viewControllers = viewControllers,
       config.selectedIndex < viewControllers.count,
       viewControllers[config.selectedIndex].tabBarItem.tag != 99 {
      selectedIndex = config.selectedIndex
    }
  }

  private func resolveSymbol(_ name: String) -> UIImage? {
    return UIImage(systemName: name) ?? UIImage(named: name)
  }

  func tabBarController(
    _ tabBarController: UITabBarController,
    shouldSelect viewController: UIViewController
  ) -> Bool {
    if viewController.tabBarItem.tag == 99 {
      channel.invokeMethod("actionButtonPressed", arguments: nil)
      return false
    }
    return true
  }

  func tabBarController(
    _ tabBarController: UITabBarController,
    didSelect viewController: UIViewController
  ) {
    let tag = viewController.tabBarItem.tag
    if tag != 99 {
      config.selectedIndex = tag
      channel.invokeMethod("valueChanged", arguments: ["index": tag])
    }
  }
}
