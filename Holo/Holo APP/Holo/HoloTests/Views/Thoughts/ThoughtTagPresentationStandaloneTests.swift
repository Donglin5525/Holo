import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        ThoughtTagPresentationStandaloneTests.main()
    }
}
#endif
struct ThoughtTagPresentationStandaloneTests {
    static func main() {
        testManualAndAITagsCoexist()
        testDuplicateTagOnlyDisplaysOnce()
        testFilteringMatchesBothSources()
        print("ThoughtTagPresentationStandaloneTests passed")
    }

    private static func testManualAndAITagsCoexist() {
        let result = ThoughtTagPresentation.card(
            manualNames: ["产品", "灵感", "待验证"],
            aiNames: ["AI 协作", "编程实践", "长期主题"]
        )

        expect(result.manualNames == ["产品", "灵感"], "应保留用户标签")
        expect(result.aiNames == ["AI 协作", "编程实践"], "有用户标签时仍应显示 AI 标签")
        expect(result.hiddenCount == 2, "未展示标签数量应正确")
    }

    private static func testDuplicateTagOnlyDisplaysOnce() {
        let result = ThoughtTagPresentation.card(
            manualNames: ["#AI 协作"],
            aiNames: [" AI 协作 ", "编程实践"]
        )

        expect(result.manualNames == ["AI 协作"], "用户标签应优先展示")
        expect(result.aiNames == ["编程实践"], "同名 AI 标签不应重复展示")
    }

    private static func testFilteringMatchesBothSources() {
        expect(
            ThoughtTagPresentation.matches("产品", manualNames: ["产品"], aiNames: ["AI 协作"]),
            "应命中用户标签"
        )
        expect(
            ThoughtTagPresentation.matches("#ai 协作", manualNames: ["产品"], aiNames: ["AI 协作"]),
            "应归一化并命中 AI 标签"
        )
        expect(
            !ThoughtTagPresentation.matches("阅读", manualNames: ["产品"], aiNames: ["AI 协作"]),
            "不相关标签不应命中"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }
}
