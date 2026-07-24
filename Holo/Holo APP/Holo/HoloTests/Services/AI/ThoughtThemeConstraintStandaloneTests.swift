// Standalone:
// swiftc ThoughtTagNormalizer.swift ThoughtThemeConstraint.swift ThoughtThemeConstraintStandaloneTests.swift -o /tmp/ThoughtThemeConstraintTests

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        ThoughtThemeConstraintStandaloneTests.main()
    }
}
#endif
struct ThoughtThemeConstraintStandaloneTests {
    static func main() {
        testValidTopicUsesCanonicalTitleAndSafePaths()
        testHallucinatedTopicFallsBackToUnclassified()
        testEmptyTopicPoolCannotBeBypassed()
        testFullWidthPathAndDuplicateAreNormalized()
        testEmptyTagsAreRejected()
        print("ThoughtThemeConstraintStandaloneTests passed")
    }

    private static func testValidTopicUsesCanonicalTitleAndSafePaths() {
        let result = ThoughtThemeConstraint.validate(
            selectedTopic: " 工作与事业 ",
            suggestedTags: ["产品规划", "工作与事业/版本发布"],
            activeTopics: ["工作与事业", "生活与健康"]
        )
        expect(result.topicTitle == "工作与事业", "应回写约束池中的标准主题名")
        expect(result.tagPaths == ["工作与事业/产品规划", "工作与事业/版本发布"], "应由端侧统一拼接路径")
    }

    private static func testHallucinatedTopicFallsBackToUnclassified() {
        let result = ThoughtThemeConstraint.validate(
            selectedTopic: "AI 自创主题",
            suggestedTags: ["大模型"],
            activeTopics: ["工作与事业"]
        )
        expect(result.topicTitle == nil, "幻觉主题不得进入分类关系")
        expect(result.tagPaths == ["未分类/大模型"], "幻觉主题必须降级为未分类路径")
    }

    private static func testEmptyTopicPoolCannotBeBypassed() {
        let result = ThoughtThemeConstraint.validate(
            selectedTopic: "财务与消费",
            suggestedTags: ["咖啡"],
            activeTopics: []
        )
        expect(result.topicTitle == nil, "空约束池不能接受模型返回的任何主题")
        expect(result.tagPaths == ["未分类/咖啡"], "空约束池仍需生成收敛路径")
    }

    private static func testFullWidthPathAndDuplicateAreNormalized() {
        let result = ThoughtThemeConstraint.validate(
            selectedTopic: "生活与健康",
            suggestedTags: ["生活与健康／跑步", "跑步", "生活与健康/睡眠"],
            activeTopics: ["生活与健康"]
        )
        expect(result.tagPaths == ["生活与健康/跑步", "生活与健康/睡眠"], "全角路径和重复标签应收敛")
    }

    private static func testEmptyTagsAreRejected() {
        let result = ThoughtThemeConstraint.validate(
            selectedTopic: "未分类",
            suggestedTags: ["", " / ", "未分类/"],
            activeTopics: ["工作与事业"]
        )
        expect(result.topicTitle == nil, "未分类不是可持久化 Topic")
        expect(result.tagPaths.isEmpty, "空标签不得写入数据库")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}

