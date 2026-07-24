import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        HoloMemorySettingsStandaloneTests.main()
    }
}
#endif
struct HoloMemorySettingsStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }

    static func main() {
        testAgentFeatureFlags_产品默认策略()
        testAgentFeatureFlags_历史关闭值会迁移到产品策略()
        testLongTermMemoryToggleControlsCandidateExtraction()
        testAIDataProcessingConsentDefaultsToNotGranted()
        testAIDataProcessingConsentPersistsGrantAndRevoke()
        testFeatureFlagReflectsAIDataProcessingConsent()
        print("HoloMemorySettings standalone tests passed")
    }

    private static func testAgentFeatureFlags_产品默认策略() {
        // 清理 UserDefaults，确保 shared 首次初始化时只应用当前产品策略。
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "holo_agent_runtimeEnabled")
        defaults.removeObject(forKey: "holo_agent_debugModeEnabled")
        defaults.removeObject(forKey: "holo_agent_memoryGalleryEnabled")
        defaults.removeObject(forKey: "holo_agent_observerTier2Enabled")
        defaults.removeObject(forKey: "holo_agent_stepIdempotencyEnabled")
        defaults.removeObject(forKey: "holo_agent_continuedProcessingEnabled")

        let settings = HoloMemorySettings.shared
        expect(settings.agentRuntimeEnabled, "agentRuntimeEnabled 产品默认应开启")
        expect(!settings.agentDebugModeEnabled, "agentDebugModeEnabled 默认应关闭")
        expect(settings.agentMemoryGalleryEnabled, "agentMemoryGalleryEnabled 产品默认应开启")
        expect(settings.agentObserverTier2Enabled, "agentObserverTier2Enabled 产品默认应开启")
        expect(settings.agentStepIdempotencyEnabled, "agentStepIdempotencyEnabled 产品默认应开启")
        expect(settings.agentContinuedProcessingEnabled, "agentContinuedProcessingEnabled 产品默认应开启")
        expect(HoloAIFeatureFlags.agentRuntimeEnabled, "HoloAIFeatureFlags.agentRuntimeEnabled 产品默认应开启")
        expect(!HoloAIFeatureFlags.agentDebugModeEnabled, "HoloAIFeatureFlags.agentDebugModeEnabled 默认应关闭")
        expect(HoloAIFeatureFlags.agentMemoryGalleryEnabled, "HoloAIFeatureFlags.agentMemoryGalleryEnabled 产品默认应开启")
        expect(HoloAIFeatureFlags.agentObserverTier2Enabled, "HoloAIFeatureFlags.agentObserverTier2Enabled 产品默认应开启")
        expect(HoloAIFeatureFlags.agentStepIdempotencyEnabled, "HoloAIFeatureFlags.agentStepIdempotencyEnabled 产品默认应开启")
        expect(HoloAIFeatureFlags.agentContinuedProcessingEnabled, "HoloAIFeatureFlags.agentContinuedProcessingEnabled 产品默认应开启")
    }

    private static func testAgentFeatureFlags_历史关闭值会迁移到产品策略() {
        let suiteName = "HoloMemorySettingsStandaloneTests.agentPolicyMigration"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        defaults.set(false, forKey: "holo_agent_runtimeEnabled")
        defaults.set(false, forKey: "holo_agent_memoryGalleryEnabled")
        defaults.set(false, forKey: "holo_agent_stepIdempotencyEnabled")
        defaults.set(false, forKey: "holo_agent_continuedProcessingEnabled")
        defaults.set(true, forKey: "holo_agent_debugModeEnabled")
        defaults.set(false, forKey: "holo_agent_observerTier2Enabled")

        let settings = HoloMemorySettings(defaults: defaults)
        expect(settings.agentRuntimeEnabled, "升级后 runtime 应按产品策略开启")
        expect(settings.agentMemoryGalleryEnabled, "升级后记忆长廊 Agent 结果应按产品策略开启")
        expect(settings.agentStepIdempotencyEnabled, "升级后请求幂等应按产品策略开启")
        expect(settings.agentContinuedProcessingEnabled, "升级后持续处理应按产品策略开启")
        expect(!settings.agentDebugModeEnabled, "升级后 Debug 模式不应被历史值开启")
        expect(settings.agentObserverTier2Enabled, "升级后 Observer 自动深挖应按产品策略开启")
        expect(defaults.bool(forKey: "holo_agent_runtimeEnabled"), "迁移结果应持久化")
        expect(defaults.bool(forKey: "holo_agent_observerTier2Enabled"), "Observer 开启策略应持久化")

        defaults.removePersistentDomain(forName: suiteName)
    }

    private static func testLongTermMemoryToggleControlsCandidateExtraction() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "holo_memory_longTermEnabled")
        defaults.removeObject(forKey: "holo_memory_insightExtractionEnabled")

        let settings = HoloMemorySettings.shared
        settings.longTermMemoryEnabled = false
        settings.memoryInsightExtractionEnabled = false

        expect(!HoloAIFeatureFlags.memoryInsightCandidateExtractionEnabled, "长期记忆关闭时不应抽取候选记忆")

        settings.longTermMemoryEnabled = true

        expect(HoloAIFeatureFlags.memoryInsightCandidateExtractionEnabled, "打开长期记忆后应启用洞察候选抽取")
    }

    private static func testAIDataProcessingConsentDefaultsToNotGranted() {
        let defaults = UserDefaults(suiteName: "HoloAIDataProcessingConsentTests.default")!
        defaults.removePersistentDomain(forName: "HoloAIDataProcessingConsentTests.default")

        let consent = HoloAIDataProcessingConsent(defaults: defaults)

        expect(!consent.isGranted, "第三方 AI 数据处理授权默认应未同意")
    }

    private static func testAIDataProcessingConsentPersistsGrantAndRevoke() {
        let suiteName = "HoloAIDataProcessingConsentTests.persist"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let consent = HoloAIDataProcessingConsent(defaults: defaults)
        consent.grant()

        let reloaded = HoloAIDataProcessingConsent(defaults: defaults)
        expect(reloaded.isGranted, "同意第三方 AI 数据处理后应持久化")

        reloaded.revoke()
        let revoked = HoloAIDataProcessingConsent(defaults: defaults)
        expect(!revoked.isGranted, "撤回第三方 AI 数据处理授权后应持久化")
    }

    private static func testFeatureFlagReflectsAIDataProcessingConsent() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "holo_ai_dataProcessingConsentGranted")

        HoloAIDataProcessingConsent.shared.revoke()
        expect(!HoloAIFeatureFlags.aiDataProcessingConsentGranted, "未同意时 AI 数据处理 feature flag 应关闭")

        HoloAIDataProcessingConsent.shared.grant()
        expect(HoloAIFeatureFlags.aiDataProcessingConsentGranted, "同意后 AI 数据处理 feature flag 应开启")

        HoloAIDataProcessingConsent.shared.revoke()
    }
}
