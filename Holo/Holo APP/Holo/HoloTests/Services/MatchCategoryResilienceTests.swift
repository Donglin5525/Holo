//
//  MatchCategoryResilienceTests.swift
//  HoloTests
//
//  分类匹配必须有完整父链；同名一级的健康分类可以复用，孤儿不能继续入账。
//  与 CategoryOrphanRepairTests 互补：父链恢复前保留历史，但拒绝新的孤儿引用。
//

import XCTest
import CoreData
@testable import Holo

// iOS 26 SDK 的某模块也导出 Category 名字，与 Holo.Category 冲突；
// 显式指回被测类型
private typealias Category = Holo.Category

@MainActor
final class MatchCategoryResilienceTests: XCTestCase {

    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try? CoreDataTestSupport.clearAllEntities(context)
    }

    override func tearDown() {
        try? CoreDataTestSupport.clearAllEntities(context)
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func makeCategory(
        name: String,
        type: String = "expense",
        parentId: UUID? = nil,
        id: UUID = UUID()
    ) -> Category {
        let category = Category.create(
            in: context,
            name: name,
            icon: "tag",
            color: "#13A4EC",
            type: type,
            isDefault: false,
            parentId: parentId,
            isSystem: false
        )
        category.id = id
        return category
    }

    private var currentMealSub: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return CategoryCandidateResolver.mealSubCategoryForHour(hour)
    }

    private func match(
        primary: String?,
        sub: String?,
        candidate: String?,
        hint: String?,
        categories: [Category]
    ) async -> Category? {
        await FinanceTransactionDraftResolver.shared.matchCategory(
            primaryCategory: primary,
            subCategory: sub,
            categoryCandidate: candidate,
            normalizedCategoryCandidate: nil,
            semanticCategoryHint: hint,
            note: candidate ?? "",
            type: .expense,
            categories: categories
        )
    }

    // MARK: - 场景A：孤儿子分类不可作为新账目候选

    func test孤儿库_语义提示餐饮_拒绝孤儿() async throws {
        let dining = makeCategory(name: "餐饮")
        let meal = makeCategory(name: currentMealSub, parentId: UUID()) // 悬空父
        try context.save()

        let matched = await match(
            primary: nil, sub: nil, candidate: "酸汤肥牛", hint: "餐饮",
            categories: [dining, meal]
        )

        XCTAssertNil(matched, "缺失父级的二级分类不得继续入账")
    }

    // MARK: - 场景B：一级分类重复（first 命中无子类的那条），兜底仍能落位

    func test一级重复_语义提示餐饮_落当前餐次() async throws {
        let diningGhost = makeCategory(name: "餐饮")            // 无子类挂靠
        let diningReal = makeCategory(name: "餐饮")             // 子类实际挂这条
        let meal = makeCategory(name: currentMealSub, parentId: diningReal.id)
        try context.save()

        let matched = await match(
            primary: nil, sub: nil, candidate: "酸汤肥牛", hint: "餐饮",
            categories: [diningGhost, diningReal, meal]         // ghost 在前，first 拿到它
        )

        XCTAssertEqual(matched?.id, meal.id, "一级重复时按名字退化查找，不落待分类")
    }

    // MARK: - 场景C：AI 直选也不能绕过父链校验

    func testAI直选_孤儿子类_拒绝匹配() async throws {
        let dining = makeCategory(name: "餐饮")
        let meal = makeCategory(name: currentMealSub, parentId: UUID()) // 悬空父
        try context.save()

        let matched = await match(
            primary: "餐饮", sub: currentMealSub, candidate: "酸汤肥牛", hint: "餐饮",
            categories: [dining, meal]
        )

        XCTAssertNil(matched, "AI 给出名字不能代替真实父级身份")
    }

    // MARK: - 场景D（回归）：健康库 + AI 直选，正常挂接命中

    func test健康库_AI直选_挂接正常的子类命中() async throws {
        let dining = makeCategory(name: "餐饮")
        let meal = makeCategory(name: currentMealSub, parentId: dining.id)
        try context.save()

        let matched = await match(
            primary: "餐饮", sub: currentMealSub, candidate: "酸汤肥牛", hint: "餐饮",
            categories: [dining, meal]
        )

        XCTAssertEqual(matched?.id, meal.id)
    }
    func test同名二级_先出现错误父级_仍命中正确父级() throws {
        let shopping = makeCategory(name: "购物")
        let dining = makeCategory(name: "餐饮")
        let wrong = makeCategory(name: "饮品", parentId: shopping.id)
        let correct = makeCategory(name: "饮品", parentId: dining.id)
        try context.save()
        let matched = CategoryMatcherService.shared.matchSingle(primaryCategory: "餐饮", subCategory: "饮品",
            type: .expense, categories: [shopping, dining, wrong, correct])
        XCTAssertEqual(matched.matchedCategory?.id, correct.id)
    }

    func test缺省一级_同名二级分属不同父级_不猜归属() throws {
        let dining = makeCategory(name: "餐饮")
        let shopping = makeCategory(name: "购物")
        let a = makeCategory(name: "饮品", parentId: dining.id)
        let b = makeCategory(name: "饮品", parentId: shopping.id)
        try context.save()
        XCTAssertNil(CategoryMatcherService.shared.matchExistingCategoryByCandidate("饮品",
            primaryCategory: "", type: .expense, categories: [dining, shopping, a, b]))
    }

    func test语义提示_其他一级下同名餐次_不能跨父级兜底() async throws {
        let dining = makeCategory(name: "餐饮")
        let shopping = makeCategory(name: "购物")
        let wrong = makeCategory(name: currentMealSub, parentId: shopping.id)
        try context.save()
        let matched = await match(primary: nil, sub: nil, candidate: "酸汤肥牛", hint: "餐饮",
            categories: [dining, shopping, wrong])
        XCTAssertNil(matched)
    }

}
