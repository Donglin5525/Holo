import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

// 进测试工程后的断言出口：记为用例失败并继续，不再崩掉整个测试进程。
// 只在本文件生效（外层 #if HOLO_XCTEST_BRIDGE 已保证仅测试工程编译）；独立脚本运行仍用标准库的 fatalError / precondition。
private func fatalError(_ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
    XCTFail(message(), file: file, line: line)
}

#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try HoloMemoryReceiptCompatibilityStandaloneTests.main()
    }
}
#endif
struct HoloMemoryReceiptCompatibilityStandaloneTests {
    static func main() throws {
        let legacyJSON = Data("""
        [{
          "id":"legacy-receipt",
          "kind":"write",
          "channel":"insight",
          "memoryIDs":["memory-1"],
          "message":"旧回执",
          "createdAt":"2026-07-15T12:00:00Z"
        }]
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode([HoloMemoryReceipt].self, from: legacyJSON)
        guard legacy.count == 1,
              legacy[0].adoptionKind == nil,
              legacy[0].batchKey == nil,
              legacy[0].readAt == nil,
              legacy[0].handledAt == nil else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail("旧回执缺少新字段时必须兼容解码")
            return
            #else
            fatalError("旧回执缺少新字段时必须兼容解码")
            #endif
        }

        let now = Date(timeIntervalSince1970: 1_752_422_400)
        let current = HoloMemoryReceipt(
            id: "current-receipt",
            kind: .write,
            channel: .chat,
            memoryIDs: ["memory-2"],
            message: "新回执",
            createdAt: now,
            adoptionKind: .automaticallyAdopted,
            batchKey: "batch-1",
            readAt: now,
            handledAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let roundTrip = try decoder.decode(
            HoloMemoryReceipt.self,
            from: encoder.encode(current)
        )
        guard roundTrip == current else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail("新回执字段必须稳定往返")
            return
            #else
            fatalError("新回执字段必须稳定往返")
            #endif
        }

        print("HoloMemoryReceiptCompatibilityStandaloneTests passed: 2 assertions")
    }
}
