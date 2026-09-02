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
        testLeafIdentityDedupAcrossForms()
        testFilteringMatchesAcrossForms()
        testDifferentTopicsSameLeafNotMatched()
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

    /// 用户 #books 与 AI 按主题前缀拼出的「工作与事业/books」是同一概念，
    /// 卡片上必须折叠成一个，不能双显示
    private static func testLeafIdentityDedupAcrossForms() {
        let result = ThoughtTagPresentation.card(
            manualNames: ["books"],
            aiNames: ["工作与事业/books", "加班"]
        )

        expect(result.manualNames == ["books"], "用户标签应保留")
        expect(result.aiNames == ["加班"], "与用户标签同叶子的 AI 路径标签不应重复展示")
        expect(result.hiddenCount == 0, "折叠后不应残留隐藏计数")
    }

    /// 点 #books 要能召回 AI 打了「工作与事业/books」的想法，反之亦然
    private static func testFilteringMatchesAcrossForms() {
        expect(
            ThoughtTagPresentation.matches("books", manualNames: [], aiNames: ["工作与事业/books"]),
            "叶子词应命中 AI 主题路径标签"
        )
        expect(
            ThoughtTagPresentation.matches("工作与事业/books", manualNames: ["books"], aiNames: []),
            "AI 主题路径标签应命中用户叶子标签"
        )
    }

    /// 不同主题下的同叶子标签不是同一身份，不能被叶子匹配误伤
    private static func testDifferentTopicsSameLeafNotMatched() {
        expect(
            !ThoughtTagPresentation.matches("工作/复盘", manualNames: ["生活/复盘"], aiNames: []),
            "不同主题的同叶子标签不应互相命中"
        )
        expect(
            ThoughtTagPresentation.card(manualNames: ["生活/复盘"], aiNames: ["工作/复盘"]).aiNames == ["工作/复盘"],
            "不同主题的同叶子标签不应在卡片上被折叠"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }
}
