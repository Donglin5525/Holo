import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        CategoryComparisonBuilderTests.main()
    }
}
#endif

/// 科目对比聚合测试（纯 Swift，不依赖 Core Data）
/// 独立运行：swiftc -parse-as-library \
///   "Holo/Models/CategoryComparison.swift" <本测试> \
///   -o /tmp/category_comparison_test && /tmp/category_comparison_test
struct CategoryComparisonBuilderTests {
    private static var assertions = 0

    // MARK: - Fixtures

    private static let foodID = UUID()
    private static let breakfastID = UUID()
    private static let lunchID = UUID()
    private static let transportID = UUID()

    private static var categories: [UUID: CategoryComparisonInfo] {
        [
            foodID: CategoryComparisonInfo(id: foodID, name: "餐饮", icon: "fork.knife", color: "FF9500", parentID: nil),
            breakfastID: CategoryComparisonInfo(id: breakfastID, name: "早餐", icon: "cup.and.saucer", color: "FF9500", parentID: foodID),
            lunchID: CategoryComparisonInfo(id: lunchID, name: "午餐", icon: "takeoutbag.and.cup.and.straw", color: "FF9500", parentID: foodID),
            transportID: CategoryComparisonInfo(id: transportID, name: "交通", icon: "car", color: "0A84FF", parentID: nil)
        ]
    }

    private static func input(_ id: UUID?, _ amount: Decimal) -> CategoryComparisonInput {
        CategoryComparisonInput(categoryID: id, amount: amount)
    }

    static func main() {
        test两期共有科目差额正确()
        test仅本期有的科目对比期为零且百分比为nil()
        test仅对比期有的科目仍出现在结果中()
        test二级科目归入父级且父级金额含子级()
        test未分类交易归入未分类组()
        test结果按差额绝对值降序()
        test二级科目按差额绝对值降序()
        test两期都为空时返回空数组()
        test按本期金额降序排列()
        test按本期金额升序排列()
        test金额排序同步作用于二级科目()
        print("✅ CategoryComparisonBuilderTests: \(assertions) assertions passed")
    }

    // MARK: - Tests

    private static func test两期共有科目差额正确() {
        let result = CategoryComparisonBuilder.build(
            current: [input(transportID, 200)],
            baseline: [input(transportID, 150)],
            categories: categories
        )

        expect(result.count == 1, "共有科目应只产出一个对比项")
        let item = result[0]
        expect(item.name == "交通", "科目名应来自分类信息")
        expect(item.currentAmount == 200, "本期金额错误")
        expect(item.baselineAmount == 150, "对比期金额错误")
        expect(item.diff == 50, "差额应为本期 - 对比期")
        expect(abs((item.diffPercentage ?? 0) - 100.0 / 3.0) < 0.001, "变化百分比错误")
    }

    private static func test仅本期有的科目对比期为零且百分比为nil() {
        let result = CategoryComparisonBuilder.build(
            current: [input(transportID, 88)],
            baseline: [],
            categories: categories
        )

        expect(result.count == 1, "仅本期的科目也应出现")
        expect(result[0].baselineAmount == 0, "对比期金额应为 0")
        expect(result[0].diff == 88, "差额应为全量")
        expect(result[0].diffPercentage == nil, "对比期为 0 时应返回 nil，由 UI 展示新增")
    }

    private static func test仅对比期有的科目仍出现在结果中() {
        let result = CategoryComparisonBuilder.build(
            current: [],
            baseline: [input(transportID, 120)],
            categories: categories
        )

        expect(result.count == 1, "仅对比期的科目不应被丢弃")
        expect(result[0].currentAmount == 0, "本期金额应为 0")
        expect(result[0].diff == -120, "差额应为负")
        expect(abs((result[0].diffPercentage ?? 0) - (-100)) < 0.001, "下降 100% 计算错误")
    }

    private static func test二级科目归入父级且父级金额含子级() {
        let result = CategoryComparisonBuilder.build(
            current: [input(breakfastID, 30), input(lunchID, 50), input(foodID, 20)],
            baseline: [input(breakfastID, 25)],
            categories: categories
        )

        expect(result.count == 1, "二级科目应归入同一个一级科目")
        let food = result[0]
        expect(food.id == foodID, "分组键应为一级科目 id")
        expect(food.name == "餐饮", "一级科目名错误")
        expect(food.currentAmount == 100, "父级本期金额应包含全部二级科目与直接记录")
        expect(food.baselineAmount == 25, "父级对比期金额错误")

        expect(food.subItems.count == 2, "应有两个二级科目对比项")
        let breakfast = food.subItems.first { $0.id == breakfastID }
        expect(breakfast?.currentAmount == 30, "早餐本期金额错误")
        expect(breakfast?.baselineAmount == 25, "早餐对比期金额错误")
        let lunch = food.subItems.first { $0.id == lunchID }
        expect(lunch?.currentAmount == 50, "午餐本期金额错误")
        expect(lunch?.baselineAmount == 0, "午餐对比期金额应为 0")
    }

    private static func test未分类交易归入未分类组() {
        let unknownID = UUID()
        let result = CategoryComparisonBuilder.build(
            current: [input(nil, 10), input(unknownID, 15)],
            baseline: [input(nil, 5)],
            categories: categories
        )

        expect(result.count == 1, "未分类应聚合为一组")
        let item = result[0]
        expect(item.id == CategoryComparisonBuilder.uncategorizedID, "未分类应使用固定 id")
        expect(item.name == "未分类", "未分类名称错误")
        expect(item.currentAmount == 25, "categoryID 缺失或科目信息不存在都应归入未分类")
        expect(item.baselineAmount == 5, "未分类对比期金额错误")
    }

    private static func test结果按差额绝对值降序() {
        let result = CategoryComparisonBuilder.build(
            current: [input(foodID, 100), input(transportID, 10)],
            baseline: [input(foodID, 150), input(transportID, 100)],
            categories: categories
        )

        expect(result.count == 2, "应有两个一级科目")
        expect(result[0].id == transportID, "差额 -90 的交通应排在差额 -50 的餐饮之前")
        expect(result[1].id == foodID, "餐饮应排第二")
    }

    private static func test二级科目按差额绝对值降序() {
        let result = CategoryComparisonBuilder.build(
            current: [input(breakfastID, 10), input(lunchID, 90)],
            baseline: [input(breakfastID, 50), input(lunchID, 10)],
            categories: categories
        )

        expect(result.count == 1, "应只有一个一级科目")
        let subs = result[0].subItems
        expect(subs.map(\.id) == [lunchID, breakfastID], "差额 80 的午餐应排在差额 -40 的早餐之前")
    }

    private static func test两期都为空时返回空数组() {
        let result = CategoryComparisonBuilder.build(current: [], baseline: [], categories: categories)
        expect(result.isEmpty, "两期都空应返回空数组")
    }

    private static func test按本期金额降序排列() {
        // 餐饮差额 100 但本期金额 100；交通差额 20 但本期金额 500
        let items = CategoryComparisonBuilder.build(
            current: [input(foodID, 100), input(transportID, 500)],
            baseline: [input(transportID, 480)],
            categories: categories
        )
        expect(items.map(\.id) == [foodID, transportID], "默认差额排序应为餐饮在前")

        let result = CategoryComparisonBuilder.sorted(items, by: .amountDescending)
        expect(result.map(\.id) == [transportID, foodID], "本期 500 的交通应排在 100 的餐饮之前")
    }

    private static func test按本期金额升序排列() {
        let items = CategoryComparisonBuilder.build(
            current: [input(foodID, 100), input(transportID, 500)],
            baseline: [input(transportID, 480)],
            categories: categories
        )
        let result = CategoryComparisonBuilder.sorted(items, by: .amountAscending)

        expect(result.map(\.id) == [foodID, transportID], "本期 100 的餐饮应排在 500 的交通之前")
    }

    private static func test金额排序同步作用于二级科目() {
        let items = CategoryComparisonBuilder.build(
            current: [input(breakfastID, 80), input(lunchID, 20)],
            baseline: [input(breakfastID, 10), input(lunchID, 70)],
            categories: categories
        )

        let ascending = CategoryComparisonBuilder.sorted(items, by: .amountAscending)
        expect(ascending[0].subItems.map(\.id) == [lunchID, breakfastID],
               "二级科目应按本期金额升序：20 的午餐在 80 的早餐前")

        let descending = CategoryComparisonBuilder.sorted(items, by: .amountDescending)
        expect(descending[0].subItems.map(\.id) == [breakfastID, lunchID],
               "二级科目应按本期金额降序：80 的早餐在 20 的午餐前")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() {
            fatalError("❌ \(message)")
        }
    }
}
