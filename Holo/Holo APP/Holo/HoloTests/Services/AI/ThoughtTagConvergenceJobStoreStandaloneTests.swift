// Standalone:
// swiftc ConvergenceSuggestion.swift ThoughtTagConvergenceJobStore.swift ThoughtTagConvergenceJobStoreStandaloneTests.swift -o /tmp/ThoughtTagConvergenceJobStoreTests

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
        ThoughtTagConvergenceJobStoreStandaloneTests.main()
    }
}
#endif
struct ThoughtTagConvergenceJobStoreStandaloneTests {
    static func main() {
        let suiteName = "ThoughtTagConvergenceJobStoreStandaloneTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail("无法创建隔离 UserDefaults")
            return
            #else
            fatalError("无法创建隔离 UserDefaults")
            #endif
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThoughtTagConvergenceJobStore(userDefaults: defaults)
        let suggestion = ConvergenceSuggestion(
            topicTitle: "工作与事业",
            matchedTopicId: nil,
            thoughtIds: [UUID(), UUID()],
            sourceTerms: ["产品规划"],
            confidence: 0.86,
            reason: "重复出现的长期方向"
        )

        store.savePendingSuggestions([suggestion], inputSignature: "signature-v1")
        let restored = store.loadPendingSuggestions()
        expect(restored?.inputSignature == "signature-v1", "应恢复输入签名")
        expect(restored?.suggestions == [suggestion], "应跨冷启动恢复完整建议")

        store.savePendingSuggestions([], inputSignature: "signature-v1")
        expect(store.loadPendingSuggestions() == nil, "建议处理完后必须清理缓存")

        print("ThoughtTagConvergenceJobStoreStandaloneTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
