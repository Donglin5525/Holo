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
        HoloMemoryAccessPolicyStandaloneTests.main()
    }
}
#endif
struct HoloMemoryAccessPolicyStandaloneTests {
    private static var assertions = 0

    static func main() {
        testAutomaticMemoryGate()
        testAnsweringGateCoversEveryConsumer()
        testConsentSeparatesLocalAndExternalExtraction()
        testLegacySettingsMigrationDoesNotSilentlyEnableMemory()
        print("HoloMemoryAccessPolicyStandaloneTests: \(assertions) assertions passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertions += 1
        guard condition() else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail(message)
            return
            #else
            fatalError(message)
            #endif
        }
    }

    private static func testAutomaticMemoryGate() {
        let policy = HoloMemoryAccessPolicy(
            state: .init(
                automaticMemoryEnabled: false,
                memoryAssistedAnsweringEnabled: true,
                aiDataProcessingConsentGranted: true
            )
        )

        expect(policy.extractionDecision(for: .localDeterministic) == .deniedByAutomaticMemorySetting,
               "关闭自动记忆后，本地萃取也必须停止")
        expect(policy.extractionDecision(for: .externalAI) == .deniedByAutomaticMemorySetting,
               "关闭自动记忆后，外部 AI 萃取必须停止")
        expect(policy.canReadExistingMemoryForManagement,
               "关闭自动记忆不能删除或隐藏用户已有记忆")
    }

    private static func testAnsweringGateCoversEveryConsumer() {
        let policy = HoloMemoryAccessPolicy(
            state: .init(
                automaticMemoryEnabled: true,
                memoryAssistedAnsweringEnabled: false,
                aiDataProcessingConsentGranted: true
            )
        )

        for consumer in HoloMemoryAnswerConsumer.allCases {
            expect(policy.answeringDecision(for: consumer) == .disabled,
                   "关闭记忆辅助回答后，\(consumer) 不得读取记忆")
        }
    }

    private static func testConsentSeparatesLocalAndExternalExtraction() {
        let policy = HoloMemoryAccessPolicy(
            state: .init(
                automaticMemoryEnabled: true,
                memoryAssistedAnsweringEnabled: true,
                aiDataProcessingConsentGranted: false
            )
        )

        expect(policy.extractionDecision(for: .localDeterministic) == .allowedLocalOnly,
               "撤回数据处理授权后，本地确定性统计仍可继续")
        expect(policy.extractionDecision(for: .externalAI) == .deniedByDataProcessingConsent,
               "撤回数据处理授权后，不得上传数据做 AI 萃取")
    }

    private static func testLegacySettingsMigrationDoesNotSilentlyEnableMemory() {
        expect(
            HoloMemorySettingsMigration.resolve(from: [:])
                == .init(automaticMemoryEnabled: false, memoryAssistedAnsweringEnabled: false),
            "新安装或没有显式旧选择时，两个记忆开关必须默认关闭"
        )
        expect(
            HoloMemorySettingsMigration.resolve(from: [
                HoloMemorySettingsMigration.LegacyKey.longTermMemoryEnabled: true,
                HoloMemorySettingsMigration.LegacyKey.memorySummaryInjectionEnabled: false
            ]) == .init(automaticMemoryEnabled: true, memoryAssistedAnsweringEnabled: false),
            "升级时应保留旧用户的显式选择"
        )
        expect(
            HoloMemorySettingsMigration.resolve(from: [
                HoloMemorySettingsMigration.LegacyKey.episodicMemoryObservationEnabled: true,
                HoloMemorySettingsMigration.LegacyKey.memorySummaryInjectionEnabled: true
            ]) == .init(automaticMemoryEnabled: true, memoryAssistedAnsweringEnabled: true),
            "任一旧自动记忆能力已开启时，应迁移为自动形成记忆"
        )
    }
}
