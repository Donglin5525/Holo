//
//  HoloMatterPlanLaunchTests.swift
//  HoloTests
//
//  Matter V2 计划启动原子契约单测（2026-09-21 方案 §8 R1 决策门）。
//
//  八条门禁（R1 未全绿不准接 UI）：
//  1. 7 条 actionable items 一次创建 1 Matter + 1 List + 7 Tasks + 10 Links
//  2. 所有 Tasks 的 listID 都是主题清单
//  3. task links 的 planOrder 持久化 0...6，context reset（冷启动模拟）后顺序不变
//  4. 重复调用两次，实体数不增加
//  5. 第 3 个任务创建时注入错误，六类对象全部为 0（整体回滚）
//  6. 已有同源 Matter 少 1 个 task link，重试仅补链并恢复原 planOrder
//  7. 无日期任务不被默认为今天
//  8. 下一步指向 planOrder = 0 的真实 taskID
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class HoloMatterPlanLaunchTests: XCTestCase {

    private static let sharedContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "HoloMatterPlanLaunchTests", managedObjectModel: CoreDataTestSupport.sharedModel)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        try? container.loadPersistentStores { _, _ in }
        return container
    }()

    private var context: NSManagedObjectContext!
    private var repo: HoloMatterRepository!

    private let fixedNow = Date(timeIntervalSince1970: 1_789_000_000)

    /// UC-MATTER-001 §5 标准输出的 7 条行动项。
    private let japanSteps: [String] = [
        "核实护照、签证与入境要求",
        "确定东京和大阪的停留天数",
        "预订往返机票",
        "安排东京与大阪之间的交通",
        "预订东京和大阪住宿",
        "确定摩卡的照顾安排",
        "准备支付、网络和出行资料"
    ]

    override func setUp() async throws {
        context = Self.sharedContainer.viewContext
        try CoreDataTestSupport.clearAllEntities(context)
        repo = HoloMatterRepository(context: context, clock: { self.fixedNow })
    }

    // MARK: - 构造

    private func makeDraft(
        items: [String]? = nil,
        unknowns: [String] = []
    ) -> HoloContextPlanDraft {
        HoloContextPlanDraft(
            runID: "run-launch-1",
            draftRevision: 1,
            goalSummary: "国庆日本旅行",
            answerText: "在出发前完成入境核实、行程分配、机票住宿、摩卡照顾和出行准备。",
            items: (items ?? japanSteps).enumerated().map { index, title in
                HoloContextPlanItem(itemID: "item-\(index)", title: title, kind: .task)
            },
            unknowns: unknowns.map { HoloContextPlanUnknown(question: $0) }
        )
    }

    private func makeRequest(
        draft: HoloContextPlanDraft? = nil,
        messageID: UUID = UUID(),
        userMessageID: UUID? = UUID(),
        title: String = "国庆日本旅行",
        existingMatterID: UUID? = nil
    ) -> HoloMatterPlanLaunchRequest {
        HoloMatterPlanLaunchRequest(
            contextPlanMessageID: messageID,
            userMessageID: userMessageID,
            draft: draft ?? makeDraft(),
            confirmedTitle: title,
            targetDate: nil,
            existingMatterID: existingMatterID
        )
    }

    private func count(_ entityName: String) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        return (try? context.count(for: request)) ?? -1
    }

    private func taskLinks(matterID: UUID) -> [HoloMatterLink] {
        let request = NSFetchRequest<HoloMatterLink>(entityName: "HoloMatterLink")
        request.predicate = NSPredicate(
            format: "matterID == %@ AND entityTypeRaw == %@",
            matterID as CVarArg,
            HoloMatterLinkEntityType.todoTask.rawValue
        )
        return ((try? context.fetch(request)) ?? []).sorted { $0.planOrder < $1.planOrder }
    }

    // MARK: - 门禁 1 + 2 + 8：原子创建 / 清单归属 / 真实下一步

    func testLaunchCreatesAtomicPlanWithTenLinksAndRealNextAction() async throws {
        let receipt = try await repo.launchPlan(request: makeRequest())

        XCTAssertEqual(count("HoloMatter"), 1)
        XCTAssertEqual(count("TodoList"), 1)
        XCTAssertEqual(count("TodoTask"), 7)
        XCTAssertEqual(count("HoloMatterLink"), 10, "origin + chatMessage + todoList + 7 todoTask = 10")
        XCTAssertTrue(receipt.createdMatter)
        XCTAssertEqual(receipt.createdTaskCount, 7)
        XCTAssertEqual(receipt.reusedTaskCount, 0)
        XCTAssertEqual(receipt.openLoopIDs, [])

        // 门禁 2：所有任务挂主题清单。
        let listID = receipt.listID
        for taskID in receipt.taskIDs {
            let request = TodoTask.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", taskID as CVarArg)
            let task = try XCTUnwrap((try? context.fetch(request))?.first)
            XCTAssertEqual(task.list?.id, listID, "任务「\(task.title)」必须归属主题清单")
            XCTAssertNil(task.dueDate, "门禁 7：无确认日期不得默认任何日期")
        }

        // 门禁 8：下一步 = planOrder 0 的真实 taskID。
        XCTAssertEqual(receipt.nextActionTaskID, receipt.taskIDs.first)
        let matter = try XCTUnwrap(repo.matter(id: receipt.matterID))
        XCTAssertEqual(matter.projection?.nextAction?.entityID, receipt.taskIDs.first?.uuidString)
        XCTAssertEqual(matter.projection?.nextAction?.title, japanSteps[0])
    }

    // MARK: - 门禁 3：planOrder 持久化 + 冷启动稳定

    func testPlanOrderPersistedAndStableAcrossContextReset() async throws {
        let receipt = try await repo.launchPlan(request: makeRequest())
        let matterID = receipt.matterID

        let before = taskLinks(matterID: matterID).filter { $0.deletedAt == nil }
        XCTAssertEqual(before.map(\.planOrder), Array(Int16(0)...6))
        XCTAssertEqual(before.map(\.entityID), receipt.taskIDs.map(\.uuidString))

        // 冷启动模拟：context.reset 后全部对象从 store 重新加载。
        context.reset()
        let after = taskLinks(matterID: matterID)
        XCTAssertEqual(after.map(\.planOrder), Array(Int16(0)...6), "冷启动后 planOrder 不得变化")
        XCTAssertEqual(after.map(\.entityID), receipt.taskIDs.map(\.uuidString))
    }

    // MARK: - 门禁 4：重复调用幂等

    func testRelaunchIsIdempotent() async throws {
        let request = makeRequest()
        let first = try await repo.launchPlan(request: request)
        let second = try await repo.launchPlan(request: request)

        XCTAssertEqual(count("HoloMatter"), 1)
        XCTAssertEqual(count("TodoList"), 1)
        XCTAssertEqual(count("TodoTask"), 7)
        XCTAssertEqual(count("HoloMatterLink"), 10)
        XCTAssertEqual(count("HoloMatterEvent"), 1, "activated 事件幂等键去重")

        XCTAssertEqual(second.matterID, first.matterID)
        XCTAssertEqual(second.listID, first.listID)
        XCTAssertEqual(second.taskIDs, first.taskIDs)
        XCTAssertFalse(second.createdMatter)
        XCTAssertEqual(second.createdTaskCount, 0)
        XCTAssertEqual(second.reusedTaskCount, 7)
        XCTAssertEqual(second.nextActionTaskID, first.nextActionTaskID)
    }

    // MARK: - 门禁 5：中途失败整体回滚

    func testFailureAtThirdTaskRollsBackEverything() async throws {
        repo.launchTaskCreationHook = { createdCount in
            if createdCount == 3 {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "注入失败"])
            }
        }
        do {
            _ = try await repo.launchPlan(request: makeRequest())
            XCTFail("应抛错")
        } catch {
            // 预期失败
        }

        for entityName in ["HoloMatter", "TodoList", "TodoTask", "HoloMatterLink", "HoloMatterOpenLoop", "HoloMatterEvent"] {
            XCTAssertEqual(count(entityName), 0, "\(entityName) 必须整体回滚为 0")
        }
    }

    // MARK: - 门禁 6：缺 1 个 task link 的修复

    func testRepairRestoresMissingLinkAndPlanOrder() async throws {
        let request = makeRequest()
        let first = try await repo.launchPlan(request: request)

        // 模拟数据缺失：物理删除 planOrder = 3 的 task link。
        let links = taskLinks(matterID: first.matterID)
        let victim = try XCTUnwrap(links.first { $0.planOrder == 3 })
        context.delete(victim)
        try context.save()
        XCTAssertEqual(taskLinks(matterID: first.matterID).count, 6)

        let second = try await repo.launchPlan(request: request)

        XCTAssertEqual(count("HoloMatter"), 1)
        XCTAssertEqual(count("TodoTask"), 7, "任务本体不重建（幂等键命中复用）")
        XCTAssertEqual(count("HoloMatterEvent"), 1)

        let repaired = taskLinks(matterID: first.matterID).filter { $0.deletedAt == nil }
        XCTAssertEqual(repaired.count, 7, "缺的 link 只补链不建任务")
        XCTAssertEqual(repaired.map(\.planOrder), Array(Int16(0)...6), "恢复后 planOrder 保持 0...6")
        XCTAssertEqual(repaired.map(\.entityID), first.taskIDs.map(\.uuidString))
        XCTAssertEqual(second.createdTaskCount, 0)
        XCTAssertEqual(second.reusedTaskCount, 7)
    }

    // MARK: - 契约附加

    func testZeroActionableItemsRejected() async throws {
        let draft = makeDraft(items: [])
        do {
            _ = try await repo.launchPlan(request: makeRequest(draft: draft))
            XCTFail("0 条可执行项不得启动")
        } catch let error as HoloMatterPlanLaunchError {
            XCTAssertEqual(error, .invalidActionableCount(0))
        }
        XCTAssertEqual(count("HoloMatter"), 0)
    }

    func testUnknownsBecomeSuggestedOpenLoops() async throws {
        let draft = makeDraft(unknowns: ["签证材料是否需要邮寄"])
        let receipt = try await repo.launchPlan(request: makeRequest(draft: draft))

        XCTAssertEqual(receipt.openLoopIDs.count, 1)
        XCTAssertEqual(count("HoloMatterOpenLoop"), 1)
        let loops = repo.openLoops(matterID: receipt.matterID, activeOnly: true)
        XCTAssertEqual(loops.first?.title, "签证材料是否需要邮寄")
    }

    func testLaunchIntoExistingMatterOnlyLinks() async throws {
        let existing = try await repo.createManualMatter(title: "国庆日本旅行", targetDate: nil)

        let request = makeRequest(title: "国庆日本旅行", existingMatterID: existing.id)
        let receipt = try await repo.launchPlan(request: request)

        XCTAssertEqual(count("HoloMatter"), 1, "不新建 Matter")
        XCTAssertFalse(receipt.createdMatter)
        XCTAssertEqual(receipt.matterID, existing.id)
        XCTAssertEqual(count("TodoTask"), 7)
        // 二次点击（重试）走 origin link 幂等修复。
        let again = try await repo.launchPlan(request: request)
        XCTAssertEqual(count("HoloMatter"), 1)
        XCTAssertEqual(count("TodoTask"), 7)
        XCTAssertFalse(again.createdMatter)
    }

    func testReusesExistingListWithSameName() async throws {
        let existingList = TodoList.create(in: context, name: "国庆日本旅行")
        try context.save()

        let receipt = try await repo.launchPlan(request: makeRequest())

        XCTAssertEqual(count("TodoList"), 1, "同名清单精确复用，不建第二个")
        XCTAssertEqual(receipt.listID, existingList.id)
    }

    func testConfirmedDateLandsOnTask() async throws {
        var draft = makeDraft()
        var item = draft.items[2]
        item.confirmedDate = fixedNow
        draft.items[2] = item

        let launchRequest = makeRequest(draft: draft)
        let receipt = try await repo.launchPlan(request: launchRequest)
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", receipt.taskIDs[2] as CVarArg)
        let task = try XCTUnwrap((try? context.fetch(request))?.first)
        XCTAssertEqual(task.dueDate, fixedNow, "用户确认的日期必须落任务")
        XCTAssertEqual(task.aiSourceItemId, "item-2")
        XCTAssertEqual(task.aiSourceMessageId, launchRequest.contextPlanMessageID.uuidString)
    }
}
