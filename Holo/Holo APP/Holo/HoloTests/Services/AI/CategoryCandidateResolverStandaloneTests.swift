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
        testTimeSensitivePrimariesConfig()
        testMealSubCategoryForHour()
        testBrandCandidatePreservesOriginalWithSemanticHint()
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

    // MARK: - 时间敏感分类配置

    private static func testTimeSensitivePrimariesConfig() {
        expect(
            CategoryCandidateResolver.timeSensitivePrimaries.contains("餐饮"),
            "餐饮应该是时间敏感分类"
        )
        expect(
            !CategoryCandidateResolver.timeSensitivePrimaries.contains("交通"),
            "交通不应是时间敏感分类"
        )
        expect(
            !CategoryCandidateResolver.timeSensitivePrimaries.contains("购物"),
            "购物不应是时间敏感分类"
        )
    }

    private static func testMealSubCategoryForHour() {
        expect(CategoryCandidateResolver.mealSubCategoryForHour(7) == "早餐", "7点应该是早餐")
        expect(CategoryCandidateResolver.mealSubCategoryForHour(9) == "早餐", "9点应该是早餐")
        expect(CategoryCandidateResolver.mealSubCategoryForHour(12) == "午餐", "12点应该是午餐")
        expect(CategoryCandidateResolver.mealSubCategoryForHour(15) == "午餐", "15点应该是午餐")
        expect(CategoryCandidateResolver.mealSubCategoryForHour(18) == "晚餐", "18点应该是晚餐")
        expect(CategoryCandidateResolver.mealSubCategoryForHour(20) == "晚餐", "20点应该是晚餐")
        expect(CategoryCandidateResolver.mealSubCategoryForHour(23) == "夜宵", "23点应该是夜宵")
        expect(CategoryCandidateResolver.mealSubCategoryForHour(3) == "夜宵", "3点应该是夜宵")
    }

    private static func testBrandCandidatePreservesOriginalWithSemanticHint() {
        let candidates = CategoryCandidateResolver.orderedCandidates(
            categoryCandidate: "麦当劳",
            normalizedCategoryCandidate: "快餐",
            semanticCategoryHint: "餐饮",
            note: "麦当劳",
            hour: 12
        )
        expect(candidates.first == "麦当劳", "品牌名候选应保留原始值")
        expect(candidates.contains("快餐"), "normalizedCategoryCandidate 应出现在候选列表中")
        expect(candidates.contains("餐饮"), "semanticCategoryHint 应出现在候选列表中")
    }
}
