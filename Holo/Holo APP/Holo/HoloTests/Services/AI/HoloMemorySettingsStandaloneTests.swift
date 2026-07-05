import Foundation

@main
struct HoloMemorySettingsStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }

    static func main() {
        testAgentFeatureFlags_默认关闭()
        testLongTermMemoryToggleControlsCandidateExtraction()
        testAIDataProcessingConsentDefaultsToNotGranted()
        testAIDataProcessingConsentPersistsGrantAndRevoke()
        testFeatureFlagReflectsAIDataProcessingConsent()
        print("HoloMemorySettings standalone tests passed")
    }

    private static func testAgentFeatureFlags_默认关闭() {
        // 清理 UserDefaults，确保 shared 首次初始化时读到默认 false（不受残留污染）
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "holo_agent_runtimeEnabled")
        defaults.removeObject(forKey: "holo_agent_debugModeEnabled")
        defaults.removeObject(forKey: "holo_agent_memoryGalleryEnabled")
        defaults.removeObject(forKey: "holo_agent_observerTier2Enabled")

        let settings = HoloMemorySettings.shared
        expect(!settings.agentRuntimeEnabled, "agentRuntimeEnabled 默认应关闭")
        expect(!settings.agentDebugModeEnabled, "agentDebugModeEnabled 默认应关闭")
        expect(!settings.agentMemoryGalleryEnabled, "agentMemoryGalleryEnabled 默认应关闭")
        expect(!settings.agentObserverTier2Enabled, "agentObserverTier2Enabled 默认应关闭")
        expect(!HoloAIFeatureFlags.agentRuntimeEnabled, "HoloAIFeatureFlags.agentRuntimeEnabled 默认应关闭")
        expect(!HoloAIFeatureFlags.agentDebugModeEnabled, "HoloAIFeatureFlags.agentDebugModeEnabled 默认应关闭")
        expect(!HoloAIFeatureFlags.agentMemoryGalleryEnabled, "HoloAIFeatureFlags.agentMemoryGalleryEnabled 默认应关闭")
        expect(!HoloAIFeatureFlags.agentObserverTier2Enabled, "HoloAIFeatureFlags.agentObserverTier2Enabled 默认应关闭")
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
