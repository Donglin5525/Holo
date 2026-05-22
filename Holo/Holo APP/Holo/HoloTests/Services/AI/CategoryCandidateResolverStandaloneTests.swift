import Foundation

@main
struct CategoryCandidateResolverStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }

    static func main() {
        testCoffeeCandidateWinsOverDiningSemanticHint()
        testGenericMealCanStillUseMealCandidate()
        print("CategoryCandidateResolver standalone tests passed")
    }

    private static func testCoffeeCandidateWinsOverDiningSemanticHint() {
        let candidates = CategoryCandidateResolver.orderedCandidates(
            categoryCandidate: "咖啡",
            normalizedCategoryCandidate: "咖啡",
            semanticCategoryHint: "餐饮",
            note: "咖啡",
            hour: 0
        )

        expect(candidates.first == "咖啡", "本地精确候选“咖啡”应优先于宽泛餐饮 hint")
        expect(!candidates.contains("夜宵"), "semanticCategoryHint=餐饮 不应把明确品类“咖啡”归一成夜宵")
    }

    private static func testGenericMealCanStillUseMealCandidate() {
        let candidates = CategoryCandidateResolver.orderedCandidates(
            categoryCandidate: "吃饭",
            normalizedCategoryCandidate: "",
            semanticCategoryHint: "餐饮",
            note: "吃饭",
            hour: 12
        )

        expect(candidates.first == "吃饭", "用户原始候选仍应先参与本地匹配")
        expect(candidates.contains("午餐"), "泛餐饮表达仍应提供按时间归一的餐次候选")
    }
}
