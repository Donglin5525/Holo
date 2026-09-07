//
//  HoloPersonalContextControlsStandaloneTests.swift
//  HoloTests
//
//  P0 空开关回退基线：四闸默认仅内部账号启用；与用户记忆开关、AI 同意相与；
//  rawFallback 依附 retrieval。全部为确定性逻辑，无 LLM。
//  standalone 运行见 scripts/run-personal-context-standalone.sh。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try HoloPersonalContextControlsStandaloneTests.main()
    }
}
#endif
struct HoloPersonalContextControlsStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() throws {
        testExternalAccountAllGatesOff()
        testInternalAccountDefaults()
        testAutomaticMemoryOnlyGatesExtraction()
        testAssistedAnsweringGatesReadPaths()
        testConsentKillsEverything()
        testIndividualKillSwitches()
        testRawFallbackDependsOnRetrieval()
        testShadowRetrieval()
        testAllOffBaseline()
        print("HoloPersonalContextControlsStandaloneTests: \(assertionCount) 断言全部通过")
    }

    private static func makeSnapshot(
        extractionKill: Bool = true,
        retrievalKill: Bool = true,
        injectionKill: Bool = true,
        rawFallbackKill: Bool = true,
        isInternalAccount: Bool = true,
        automaticMemory: Bool = true,
        assistedAnswering: Bool = true,
        consent: Bool = true
    ) -> HoloPersonalContextControlSnapshot {
        HoloPersonalContextControlSnapshot(
            extractionKillEnabled: extractionKill,
            retrievalKillEnabled: retrievalKill,
            planningInjectionKillEnabled: injectionKill,
            rawFallbackKillEnabled: rawFallbackKill,
            isInternalAccount: isInternalAccount,
            automaticMemoryEnabled: automaticMemory,
            memoryAssistedAnsweringEnabled: assistedAnswering,
            aiDataProcessingConsentGranted: consent
        )
    }

    /// 非内部账号：即便所有 kill 键与用户开关全开，四个能力闸也全部关闭。
    static func testExternalAccountAllGatesOff() {
        let snapshot = makeSnapshot(isInternalAccount: false)
        expect(!snapshot.allowsExtraction, "非内部账号不得萃取")
        expect(!snapshot.allowsRetrieval, "非内部账号不得检索")
        expect(!snapshot.allowsPlanningInjection, "非内部账号不得注入回答")
        expect(!snapshot.allowsRawFallback, "非内部账号不得原文兜底")
    }

    /// 内部账号 + 全部开关默认开：四闸可用（首版灰度默认态）。
    static func testInternalAccountDefaults() {
        let snapshot = makeSnapshot()
        expect(snapshot.allowsExtraction, "内部账号默认应允许萃取")
        expect(snapshot.allowsRetrieval, "内部账号默认应允许检索")
        expect(snapshot.allowsPlanningInjection, "内部账号默认应允许注入")
        expect(snapshot.allowsRawFallback, "内部账号默认应允许原文兜底")
        expect(!snapshot.isShadowRetrieval, "全开时不属于 shadow 计数态")
    }

    /// 「自动形成记忆关、辅助回答开」：萃取/补建停，读取类闸不受影响。
    static func testAutomaticMemoryOnlyGatesExtraction() {
        let snapshot = makeSnapshot(automaticMemory: false)
        expect(!snapshot.allowsExtraction, "自动记忆关闭时不得萃取/补建")
        expect(snapshot.allowsRetrieval, "自动记忆关闭不封锁既有内容读取")
        expect(snapshot.allowsPlanningInjection, "自动记忆关闭不封锁注入")
    }

    /// 「辅助回答关」：新情境读取、注入、原文兜底全停；萃取按自身开关独立处理。
    static func testAssistedAnsweringGatesReadPaths() {
        let snapshot = makeSnapshot(assistedAnswering: false)
        expect(snapshot.allowsExtraction, "辅助回答关闭不封锁萃取（跟随自动记忆开关）")
        expect(!snapshot.allowsRetrieval, "辅助回答关闭时不得新情境读取")
        expect(!snapshot.allowsPlanningInjection, "辅助回答关闭时不得注入")
        expect(!snapshot.allowsRawFallback, "辅助回答关闭时不得原文兜底")
    }

    /// AI 数据处理未同意：任何文本/向量都不得外发，四闸全灭（含萃取）。
    static func testConsentKillsEverything() {
        let snapshot = makeSnapshot(consent: false)
        expect(!snapshot.allowsExtraction, "未同意时不得外发萃取输入")
        expect(!snapshot.allowsRetrieval, "未同意时不得外发检索向量")
        expect(!snapshot.allowsPlanningInjection, "未同意时不得注入")
        expect(!snapshot.allowsRawFallback, "未同意时不得原文兜底")
    }

    /// kill 键逐个生效，互不牵连。
    static func testIndividualKillSwitches() {
        expect(!makeSnapshot(extractionKill: false).allowsExtraction
                && makeSnapshot(extractionKill: false).allowsRetrieval,
               "关 extraction 只停萃取")
        expect(!makeSnapshot(retrievalKill: false).allowsRetrieval
                && makeSnapshot(retrievalKill: false).allowsExtraction,
               "关 retrieval 只停检索")
        expect(!makeSnapshot(injectionKill: false).allowsPlanningInjection
                && makeSnapshot(injectionKill: false).allowsRetrieval,
               "关 injection 只停注入")
    }

    /// rawFallback 的 kill 键独立：检索开着但兜底关 → 允许检索、禁止兜底。
    static func testRawFallbackDependsOnRetrieval() {
        let fallbackKilled = makeSnapshot(rawFallbackKill: false)
        expect(fallbackKilled.allowsRetrieval, "兜底关闭不影响检索本体")
        expect(!fallbackKilled.allowsRawFallback, "兜底 kill 键生效")
        let retrievalKilled = makeSnapshot(retrievalKill: false)
        expect(!retrievalKilled.allowsRawFallback, "检索关闭时兜底必须联动关闭")
    }

    /// retrieval 开、injection 关 = shadow 计数态：只做脱敏计数，不进用户回答。
    static func testShadowRetrieval() {
        let shadow = makeSnapshot(injectionKill: false)
        expect(shadow.allowsRetrieval, "shadow 态检索仍在跑")
        expect(shadow.isShadowRetrieval, "injection 关闭时应处于 shadow 计数态")
        let notRetrieving = makeSnapshot(retrievalKill: false)
        expect(!notRetrieving.isShadowRetrieval, "检索都没跑不算 shadow")
    }

    /// 全关快照：任何组合都不得打开任何能力闸（回滚时的最终形态）。
    static func testAllOffBaseline() {
        let snapshot = HoloPersonalContextControls.allOff()
        expect(!snapshot.allowsExtraction && !snapshot.allowsRetrieval
               && !snapshot.allowsPlanningInjection && !snapshot.allowsRawFallback
               && !snapshot.isShadowRetrieval,
               "全关快照必须全部能力闸关闭")
    }
}
