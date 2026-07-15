import Flutter
import UIKit
import XCTest

class RunnerTests: XCTestCase {

  func testShortcutPersistsBeforeNetworkAndUsesStablePayloadID() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("BankMessageShortcuts/BankMessageShortcuts.swift")
    )
    let persist = try XCTUnwrap(source.range(of: "status: .pendingSend"))
    let network = try XCTUnwrap(source.range(of: "let attempt = await processBackend"))
    XCTAssertLessThan(persist.lowerBound, network.lowerBound)
    XCTAssertTrue(source.contains("SharedCaptureStore.remove(payloadID: payloadID)"))
  }

  func testSharedCaptureStoresRemainByteIdentical() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let paths = [
      "Runner/SharedCaptureStore.swift",
      "BankMessageShortcuts/SharedCaptureStore.swift",
      "ShareBankMessage/SharedCaptureStore.swift",
    ]
    let values = try paths.map {
      try Data(contentsOf: root.appendingPathComponent($0))
    }
    XCTAssertEqual(values[0], values[1])
    XCTAssertEqual(values[1], values[2])
  }
}
