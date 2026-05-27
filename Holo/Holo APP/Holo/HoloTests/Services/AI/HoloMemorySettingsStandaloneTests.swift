import Foundation

@main
struct HoloMemorySettingsStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }

    static func main() {
        testLongTermMemoryToggleControlsCandidateExtraction()
        print("HoloMemorySettings standalone tests passed")
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
}
