//
//  MatchCategoryResilienceTests.swift
//  HoloTests
//
//  2026-09-25 酸汤肥牛落待分类治理：分类匹配对异常库形态（孤儿子分类/
//  一级分类重复）的容错测试。背景：真实库的父子挂接断裂（CloudKit 同步/
//  历史恢复遗留）曾让按 parentId 的子类查找全链失配，AI 明确给出「餐饮」
//  语义也静默落「待分类」。容错原则：实体在、名字对 → 就能落位。
//
//  与 CategoryOrphanRepairTests 互补：那边修库（接回连线），这边保证
//  连线接好前匹配链也不再失败。
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

    // MARK: - 场景A：孤儿子分类（parentId 悬空），语义提示兜底仍能落位

    func test孤儿库_语义提示餐饮_落当前餐次() async throws {
        let dining = makeCategory(name: "餐饮")
        let meal = makeCategory(name: currentMealSub, parentId: UUID()) // 悬空父
        try context.save()

        let matched = await match(
            primary: nil, sub: nil, candidate: "酸汤肥牛", hint: "餐饮",
            categories: [dining, meal]
        )

        XCTAssertEqual(matched?.id, meal.id, "孤儿子类应按名字落位，而非掉进待分类")
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

    // MARK: - 场景C：AI 直选（primary+sub 都给出），孤儿子类仍精确落位

    func testAI直选_孤儿子类_第2步严格匹配通过() async throws {
        let dining = makeCategory(name: "餐饮")
        let meal = makeCategory(name: currentMealSub, parentId: UUID()) // 悬空父
        try context.save()

        let matched = await match(
            primary: "餐饮", sub: currentMealSub, candidate: "酸汤肥牛", hint: "餐饮",
            categories: [dining, meal]
        )

        XCTAssertEqual(matched?.id, meal.id, "AI 直选 + 孤儿子类：名字精确匹配应放行")
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
}
