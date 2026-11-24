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
        ThoughtAIClassificationPolicyStandaloneTests.main()
    }
}
#endif
struct ThoughtAIClassificationPolicyStandaloneTests {
    static func main() {
        testDefaultAndStoredSetting()
        testInitialStatus()
        testDisabledThoughtCanStillBeManuallyOrganized()
        print("ThoughtAIClassificationPolicyStandaloneTests passed")
    }

    private static func testDefaultAndStoredSetting() {
        let suiteName = "ThoughtAIClassificationPolicyStandaloneTests"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail("无法创建测试 UserDefaults")
            return
            #else
            fatalError("无法创建测试 UserDefaults")
            #endif
        }
        defaults.removePersistentDomain(forName: suiteName)

        // 2026-09-24 方案 §6.2 停算矩阵：显式设置永远优先；未设置时跟随 V3 新 UI
        // 旗标取反（新 UI 构建默认停用 V2 自动整理，旧 UI 构建/线上 Release 默认开）
        expect(
            ThoughtAIClassificationPolicy.isEnabled(in: defaults)
                == !ThoughtSemanticFeatureFlags.uiEnabled(in: defaults),
            "未设置时默认值应与新 UI 旗标取反一致"
        )
        defaults.set(false, forKey: ThoughtAIClassificationPolicy.isEnabledKey)
        expect(!ThoughtAIClassificationPolicy.isEnabled(in: defaults), "应读取用户关闭状态")
        defaults.removePersistentDomain(forName: suiteName)
    }

    private static func testInitialStatus() {
        expect(
            ThoughtAIClassificationPolicy.initialStatus(contentLength: 20, isEnabled: false) == "disabled",
            "关闭时新想法应标记为 disabled"
        )
        expect(
            ThoughtAIClassificationPolicy.initialStatus(contentLength: 9, isEnabled: true) == "skipped",
            "过短内容应跳过 AI 分类"
        )
        expect(
            ThoughtAIClassificationPolicy.initialStatus(contentLength: 10, isEnabled: true) == "pending",
            "达到长度阈值后应进入自动分类队列"
        )
    }

    private static func testDisabledThoughtCanStillBeManuallyOrganized() {
        expect(
            !ThoughtAIClassificationPolicy.manualBatchTerminalStatuses.contains("disabled"),
            "关闭自动分类创建的想法必须仍可手动批量整理"
        )
        expect(
            ThoughtAIClassificationPolicy.manualBatchTerminalStatuses.contains("organized"),
            "已整理想法不应重复进入手动批量"
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
