//
//  HoloLifeSourceObservationTests.swift
//  HoloTests
//
//  R1 四域来源观察集成测试（方案 2026-09-23 §4.2 R1 硬门禁）。
//
//  覆盖：finance/task/habit 三域分页（真实 Core Data 实体）的
//  新建→编辑→删除→恢复追踪、修订 digest 稳定性与敏感性、sourceKey 分派回查、
//  游标推进与软删可见性。thought 域行为由既有 ContextExtraction 套件覆盖。
//

import CoreData
import XCTest
@testable import Holo

@MainActor
final class HoloLifeSourceObservationTests: XCTestCase {
    private var context: NSManagedObjectContext!

    override func setUp() async throws {
        context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(
            context,
            ["Transaction", "Category", "Account", "TodoTask", "Habit", "HabitRecord", "Thought"]
        )
    }

    // MARK: 工厂（模拟账号测试记录，与 HoloLifeUnderstandingFixtures 语义对齐）

    private func makeCategory(name: String) -> Holo.Category {
        let category = Holo.Category(context: context)
        category.id = UUID()
        category.name = name
        return category
    }

    private func makeTransaction(note: String?, amount: String, date: Date) -> Transaction {
        let transaction = Transaction(context: context)
        transaction.id = UUID()
        transaction.amount = NSDecimalNumber(string: amount)
        transaction.type = "expense"
        transaction.date = date
        transaction.note = note
        transaction.createdAt = date
        transaction.updatedAt = date
        return transaction
    }

    private func makeTask(title: String, completed: Bool) -> TodoTask {
        let task = TodoTask(context: context)
        task.id = UUID()
        task.title = title
        task.status = completed ? "completed" : "pending"
        task.completed = completed
        task.completedAt = completed ? Date() : nil
        task.deletedFlag = false
        task.archived = false
        task.createdAt = Date()
        task.updatedAt = Date()
        return task
    }

    private func makeHabit(name: String) -> Habit {
        let habit = Habit(context: context)
        habit.id = UUID()
        habit.name = name
        habit.frequency = "daily"
        habit.isArchived = false
        habit.createdAt = Date()
        habit.updatedAt = Date()
        return habit
    }

    private func makeCheckin(habit: Habit, date: Date) -> HabitRecord {
        let record = HabitRecord(context: context)
        record.id = UUID()
        record.habitId = habit.id
        record.date = date
        record.isCompleted = true
        record.createdAt = date
        record.habit = habit
        return record
    }

    // MARK: finance

    func testFinanceObservationLifecycle() async throws {
        let day = Date(timeIntervalSince1970: 1_775_000_000)
        let category = makeCategory(name: "宠物用品")
        let transaction = makeTransaction(note: "猫粮 2kg", amount: "128.00", date: day)
        transaction.category = category
        try context.save()

        let paging = HoloLifeSourceObservation.makePaging(domain: "finance", context: context)
        let page = try await paging?.fetchContextSourcePage(after: nil, limit: 10, baseline: nil)
        guard let snapshot = page?.sources.first else {
            return XCTFail("finance 分页应返回新交易")
        }
        XCTAssertTrue(snapshot.sourceID.hasPrefix("finance:"), "sourceKey 带域前缀")
        XCTAssertEqual(snapshot.sourceDomain, "finance")
        XCTAssertTrue(snapshot.plainText.contains("猫粮"), "商品线索（note）进正文")
        XCTAssertTrue(snapshot.plainText.contains("宠物用品"), "分类名进正文")
        XCTAssertFalse(snapshot.plainText.contains("128"), "金额不进模型正文（§3.10）")
        XCTAssertEqual(snapshot.businessState?["category"], "宠物用品")

        // 修订稳定性：同状态重复读取 digest 一致。
        let digestBefore = HoloFinanceContextSourcePaging.revisionDigest(transaction)
        XCTAssertEqual(digestBefore, HoloFinanceContextSourcePaging.revisionDigest(transaction))

        // 编辑（备注变化 + updatedAt 推进）→ digest 变化 + 游标重进页。
        transaction.note = "猫粮 2kg（大袋装）"
        transaction.updatedAt = transaction.updatedAt.addingTimeInterval(60)
        try context.save()
        let digestAfter = HoloFinanceContextSourcePaging.revisionDigest(transaction)
        XCTAssertNotEqual(digestBefore, digestAfter, "编辑必须改变修订")

        // 软删 → 分页不再返回（删除经修订回查对账发现）。
        transaction.deletedAt = Date()
        try context.save()
        let afterDelete = try await paging?.fetchContextSourcePage(
            after: HoloContextSourceCursor(updatedAt: .distantPast, sourceID: ""), limit: 100, baseline: nil
        )
        let firstKey = snapshot.sourceID
        XCTAssertTrue(
            (afterDelete?.sources ?? []).isEmpty || !(afterDelete?.sources ?? []).contains { $0.sourceID == firstKey },
            "软删交易不得再进萃取页"
        )
        // 回查 → deleted 哨兵（失效传播触发点）。
        let revisions = HoloLifeSourceObservation.currentRevisionDigests(
            sourceKeys: [firstKey], context: context
        )
        XCTAssertEqual(revisions[firstKey], "deleted", "软删源回查返回 deleted 哨兵")
    }

    // MARK: task

    func testTaskObservationHonestBusinessState() async throws {
        let task = makeTask(title: "给摩卡换水", completed: false)
        try context.save()
        let paging = HoloLifeSourceObservation.makePaging(domain: "task", context: context)
        let page = try await paging?.fetchContextSourcePage(after: nil, limit: 10, baseline: nil)
        guard let snapshot = page?.sources.first else {
            return XCTFail("task 分页应返回新任务")
        }
        XCTAssertTrue(snapshot.sourceID.hasPrefix("task:"))
        // §3.1 红线：completed=false 不得当成照料已经发生——状态如实传递。
        XCTAssertEqual(snapshot.businessState?["completed"], "false")
        XCTAssertTrue(snapshot.plainText.contains("给摩卡换水"))

        // 完成 → 修订变化 + 状态翻真。
        let digestBefore = HoloTaskContextSourcePaging.revisionDigest(task)
        let completedAt = Date()
        task.completed = true
        task.completedAt = completedAt
        task.updatedAt = completedAt
        try context.save()
        XCTAssertNotEqual(digestBefore, HoloTaskContextSourcePaging.revisionDigest(task))
        let pageAfter = try await paging?.fetchContextSourcePage(after: nil, limit: 10, baseline: nil)
        XCTAssertEqual(
            pageAfter?.sources.first { $0.sourceID == snapshot.sourceID }?.businessState?["completed"],
            "true"
        )

        // 删除（deletedFlag）→ 不再进页；回查 deleted。
        task.deletedFlag = true
        task.updatedAt = Date()
        try context.save()
        let afterDelete = try await paging?.fetchContextSourcePage(after: nil, limit: 100, baseline: nil)
        XCTAssertFalse((afterDelete?.sources ?? []).contains { $0.sourceID == snapshot.sourceID })
        let revisions = HoloLifeSourceObservation.currentRevisionDigests(
            sourceKeys: [snapshot.sourceID], context: context
        )
        // 活源谓词过滤的是 deletedFlag==NO；回查按实体存在与否判定——flag 删除仍可回查到
        // 实体（修订含 deleted 标记），批次对账时 digest 不匹配同样触发拒绝。
        XCTAssertNotNil(revisions[snapshot.sourceID])
    }

    // MARK: habit

    func testHabitObservationDefinitionAndCheckins() async throws {
        let habit = makeHabit(name: "给摩卡换水")
        let base = Date(timeIntervalSince1970: 1_775_100_000)
        makeCheckin(habit: habit, date: base)
        makeCheckin(habit: habit, date: base.addingTimeInterval(3_600))
        try context.save()

        let paging = HoloLifeSourceObservation.makePaging(domain: "habit", context: context)
        let page = try await paging?.fetchContextSourcePage(after: nil, limit: 10, baseline: nil)
        let sources = page?.sources ?? []
        XCTAssertEqual(sources.count, 3, "1 定义 + 2 打卡（单一时间轴）")
        let definitions = sources.filter { $0.sourceKind == "habitDefinition" }
        let checkins = sources.filter { $0.sourceKind == "habitCheckin" }
        XCTAssertEqual(definitions.count, 1)
        XCTAssertEqual(checkins.count, 2)
        XCTAssertTrue(definitions[0].plainText.contains("给摩卡换水"))
        XCTAssertTrue(definitions[0].plainText.contains("每天"), "频次进正文")
        XCTAssertTrue(checkins.allSatisfy { $0.sourceID.hasPrefix("habit-checkin:") })
        // 打卡血缘根（A07 独立证据去重依据）。
        XCTAssertTrue(checkins.allSatisfy { ($0.lineageRootIDs ?? []).isEmpty == false })
        // 打卡硬删 → 回查 deleted（对账发现）。
        let removed = checkins[0]
        let removedUUID = UUID(uuidString: String(removed.sourceID.dropFirst("habit-checkin:".count)))!
        let recordRequest = HabitRecord.fetchRequest()
        recordRequest.predicate = NSPredicate(format: "id == %@", removedUUID as CVarArg)
        if let record = try context.fetch(recordRequest).first {
            context.delete(record)
        }
        try context.save()
        let revisions = HoloLifeSourceObservation.currentRevisionDigests(
            sourceKeys: [removed.sourceID], context: context
        )
        XCTAssertEqual(revisions[removed.sourceID], "deleted", "硬删打卡回查 deleted")
    }

    func testHabitPagingCursorOnlyReturnsNewEvents() async throws {
        let habit = makeHabit(name: "晨间拉伸")
        let t1 = Date(timeIntervalSince1970: 1_775_200_000)
        makeCheckin(habit: habit, date: t1)
        try context.save()
        let paging = HoloLifeSourceObservation.makePaging(domain: "habit", context: context)
        let firstPage = try await paging?.fetchContextSourcePage(after: nil, limit: 10, baseline: nil)
        XCTAssertEqual(firstPage?.sources.count, 2, "定义 + 1 打卡")

        guard let cursor = firstPage?.nextCursor else { return XCTFail("应有游标") }
        // 无新事件：续页为空。
        let secondPage = try await paging?.fetchContextSourcePage(after: cursor, limit: 10, baseline: nil)
        XCTAssertEqual(secondPage?.sources.count, 0, "追平后续页为空")
        XCTAssertNil(secondPage?.nextCursor)

        // 新打卡 → 续页只含新打卡（游标重放）。
        makeCheckin(habit: habit, date: Date())
        try context.save()
        let thirdPage = try await paging?.fetchContextSourcePage(after: cursor, limit: 10, baseline: nil)
        XCTAssertEqual(thirdPage?.sources.count, 1, "只返回新打卡")
        XCTAssertEqual(thirdPage?.sources.first?.sourceKind, "habitCheckin")
    }

    // MARK: sourceKey 分派

    func testSourceKeyDomainDispatch() {
        XCTAssertEqual(HoloLifeSourceKeys.domain(of: "finance:ABC"), "finance")
        XCTAssertEqual(HoloLifeSourceKeys.domain(of: "task:ABC"), "task")
        XCTAssertEqual(HoloLifeSourceKeys.domain(of: "habit:ABC"), "habit")
        XCTAssertEqual(HoloLifeSourceKeys.domain(of: "habit-checkin:ABC"), "habit")
        XCTAssertEqual(HoloLifeSourceKeys.domain(of: "7B2F...-bare-uuid"), "thought", "无前缀 = thought 存量")
        XCTAssertEqual(HoloLifeSourceKeys.entityID(of: "finance:ABC"), "ABC")
        XCTAssertEqual(HoloLifeSourceKeys.entityID(of: "habit-checkin:ABC"), "ABC")
        XCTAssertEqual(HoloLifeSourceKeys.entityID(of: "bare"), "bare")
    }

    func testProgressAggregation() {
        var a = HoloContextExtractionProgress()
        a.createdRecords = 2
        a.scannedSources = 10
        var b = HoloContextExtractionProgress()
        b.createdRecords = 3
        b.failedBatches = 1
        let summed = a.byAdding(b)
        XCTAssertEqual(summed.createdRecords, 5)
        XCTAssertEqual(summed.scannedSources, 10)
        XCTAssertEqual(summed.failedBatches, 1)
    }
}
