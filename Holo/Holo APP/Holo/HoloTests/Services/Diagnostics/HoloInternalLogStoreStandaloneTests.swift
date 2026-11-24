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
        try HoloInternalLogStoreStandaloneTests.main()
    }
}
#endif
struct HoloInternalLogStoreStandaloneTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = HoloInternalLogStore(directoryURL: root, now: { now })
        expect(!FileManager.default.fileExists(atPath: root.path), "未授权使用前不应创建目录")

        let currentId = UUID()
        let expiredId = UUID()
        try store.save(record(messageId: expiredId, date: now.addingTimeInterval(-8 * 24 * 60 * 60)))
        try store.save(record(messageId: currentId, date: now))
        expect(store.contains(messageId: currentId), "7 天内日志应保留")
        expect(!store.contains(messageId: expiredId), "超过 7 天日志应清理")
        expect(store.createsSharedContainerData == false, "日志不得写入共享容器")

        let file = root.appendingPathComponent("ai-logs.json")
        try Data("broken".utf8).write(to: file)
        expect(store.log(for: currentId) == nil, "损坏 JSON 应安全恢复为空")
        store.clear()
        expect(!FileManager.default.fileExists(atPath: root.path), "退出后应清空内部日志目录")
        print("HoloInternalLogStoreStandaloneTests: PASS")
    }

    private static func record(messageId: UUID, date: Date) -> HoloInternalLogRecord {
        HoloInternalLogRecord(
            messageId: messageId,
            requestId: UUID().uuidString,
            capturedAt: date,
            log: LLMLog(calls: [LLMCallLog(
                type: "chat",
                model: "internal",
                requestMessages: [.user("test")],
                responseText: "ok"
            )])
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail(message)
            return
            #else
            fatalError(message)
            #endif
        }
    }
}
