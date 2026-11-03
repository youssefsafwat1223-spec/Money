import Flutter
import Foundation
import Security
import UIKit

/// ASR design v7.2 §6.1 — a status-preserving Keychain API for the session store.
///
/// `flutter_secure_storage` maps `errSecItemNotFound` to a successful `nil`
/// (FlutterSecureStorage.swift:130-132) and its Dart side cannot tell "absent"
/// from "temporarily unavailable" (before first unlock, `errSecInteractionNotAllowed`)
/// in every path. The session store and the ASR eligibility reads need that
/// distinction: an unavailable read must defer or deny, never read as empty.
///
/// Every operation runs on ONE serial queue, so a reload enqueued after a write
/// whose reply was lost observes that write's outcome (§6.3): it can neither land
/// later nor overwrite a successor.
///
/// Items this file OWNS (the session record) are device-only
/// (`AfterFirstUnlockThisDeviceOnly`, owner decision (f)) and never synchronizable.
/// `readPluginItem` only READS items written by `flutter_secure_storage`, using the
/// plugin's own query shape, and never writes them.
final class SessionKeychain {
  static let channelName = "qirsh/session_keychain"

  /// Service for items owned by this file. Distinct from the plugin's default
  /// service, so no plugin read/write/deleteAll can touch the session record.
  static let ownService = "qirsh.session"

  /// `flutter_secure_storage`'s default service (apple_options.dart:37).
  static let pluginService = "flutter_secure_storage_service"

  private let queue = DispatchQueue(label: "qirsh.session_keychain")
  private var channel: FlutterMethodChannel?
  private var protectedDataObserver: NSObjectProtocol?

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
    self.channel = channel
    if protectedDataObserver == nil {
      protectedDataObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.protectedDataDidBecomeAvailableNotification,
        object: nil, queue: .main
      ) { [weak self] _ in
        self?.channel?.invokeMethod("protectedDataDidBecomeAvailable", arguments: nil)
      }
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "protectedDataAvailable":
      result(UIApplication.shared.isProtectedDataAvailable)
    case "read", "write", "delete", "readPluginItem":
      guard let key = args["key"] as? String, !key.isEmpty else {
        result(FlutterError(code: "bad_args", message: "key", details: nil))
        return
      }
      let value = args["value"] as? String
      let method = call.method
      queue.async {
        let reply: [String: Any]
        switch method {
        case "read": reply = Self.read(service: Self.ownService, account: key)
        case "write":
          reply = value.map { Self.write(account: key, value: $0) }
            ?? ["status": "error", "code": Int(errSecParam)]
        case "delete": reply = Self.delete(service: Self.ownService, account: key)
        default: reply = Self.readPlugin(account: key)
        }
        DispatchQueue.main.async { result(reply) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Status mapping

  /// `found` / `absent` / `unavailable` (protected data not available) /
  /// `error` (any other status: callers treat it as restrictive).
  static func classify(_ status: OSStatus) -> String {
    switch status {
    case errSecSuccess: return "found"
    case errSecItemNotFound: return "absent"
    case errSecInteractionNotAllowed: return "unavailable"
    default: return "error"
    }
  }

  // MARK: - Owned items

  private static func baseQuery(service: String, account: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
  }

  static func read(service: String, account: String) -> [String: Any] {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var ref: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &ref)
    var reply: [String: Any] = ["status": classify(status), "code": Int(status)]
    if status == errSecSuccess {
      guard let data = ref as? Data, let value = String(data: data, encoding: .utf8) else {
        return ["status": "error", "code": Int(errSecDecode)]
      }
      reply["value"] = value
    }
    return reply
  }

  /// Update-then-add of a device-only item. Success means the OS reported success
  /// for the call that changed the item (the §6.3 linearization point).
  static func write(account: String, value: String) -> [String: Any] {
    guard let data = value.data(using: .utf8) else {
      return ["status": "error", "code": Int(errSecParam)]
    }
    let query = baseQuery(service: ownService, account: account)
    let attrs: [CFString: Any] = [
      kSecValueData: data,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
    if status == errSecItemNotFound {
      var add = query
      add[kSecValueData] = data
      add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      add[kSecAttrSynchronizable] = false
      status = SecItemAdd(add as CFDictionary, nil)
    }
    return ["status": status == errSecSuccess ? "ok" : classify(status), "code": Int(status)]
  }

  static func delete(service: String, account: String) -> [String: Any] {
    let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    let s: String
    switch status {
    case errSecSuccess, errSecItemNotFound: s = "ok"
    default: s = classify(status)
    }
    return ["status": s, "code": Int(status)]
  }

  // MARK: - flutter_secure_storage items (read only)

  /// The plugin's own read shape (FlutterSecureStorage.swift:118-146): first
  /// without `kSecAttrSynchronizable`, then with `true` when nothing was found.
  /// Unlike the plugin, every non-success status is preserved.
  static func readPlugin(account: String) -> [String: Any] {
    func query(synchronizable: Bool?) -> (OSStatus, AnyObject?) {
      var q = baseQuery(service: pluginService, account: account)
      if let synchronizable { q[kSecAttrSynchronizable] = synchronizable }
      q[kSecMatchLimit] = kSecMatchLimitOne
      q[kSecReturnData] = true
      var ref: AnyObject?
      let status = SecItemCopyMatching(q as CFDictionary, &ref)
      return (status, ref)
    }
    var (status, ref) = query(synchronizable: nil)
    if status == errSecItemNotFound {
      (status, ref) = query(synchronizable: true)
    }
    var reply: [String: Any] = ["status": classify(status), "code": Int(status)]
    if status == errSecSuccess {
      guard let data = ref as? Data, let value = String(data: data, encoding: .utf8) else {
        return ["status": "error", "code": Int(errSecDecode)]
      }
      reply["value"] = value
    }
    return reply
  }
}
