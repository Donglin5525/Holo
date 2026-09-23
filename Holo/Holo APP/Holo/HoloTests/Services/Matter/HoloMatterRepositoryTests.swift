//
//  HoloMatterRepositoryTests.swift
//  HoloTests
//
//  Matter Repository 单测（方案 §18.1 - 激活幂等/事务/权限/撤销）
//
//  覆盖（使用隔离 in-memory store，不触碰真实用户库）：
//  - 激活：创建成功、同一来源幂等、unknowns→suggested loop、更新到已有 Matter
//  - 生命周期：合法流转 + 非法迁移拒绝
//  - Open Loop：confirm、assistant 权限约束（不可复活已解决项）
//  - Link：幂等折叠、拒绝保留 suppression
//  - 撤销：反向事件回滚，审计不消失
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class HoloMatterRepositoryTests: XCTestCase {

    /// 进程级共享容器（CoreDataTestSupport.sharedModel 避免多模型互踩）
    private static let sharedContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "HoloMatterRepositoryTests", managedObjectModel: CoreDataTestSupport.sharedModel)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        try? container.loadPersistentStores { _, _ in }
        return container
    }()

    private var context: NSManagedObjectContext!
    private var repo: HoloMatterRepository!

    /// 固定时钟，测试时间语义可复现。
    private let fixedNow = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUp() async throws {
        context = Self.sharedContainer.viewContext

        // 清空上一用例（in-memory store 逐实体 fetch+delete）
        for entityName in ["HoloMatter", "HoloMatterOpenLoop", "HoloMatterLink", "HoloMatterEvent"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            for object in (try? context.fetch(request)) ?? [] {
                context.delete(object)
            }
        }
        try? context.save()

        repo = HoloMatterRepository(context: context, clock: { self.fixedNow })
    }

    // MARK: - 构造激活请求

    private func makeRequest(
        messageID: UUID = UUID(),
        title: String = "国庆日本旅行",
        unknowns: [String] = ["猫咪由谁照顾", "预订京都住宿"],
        targetDate: Date? = nil,
        existingMatterID: UUID? = nil
    ) -> HoloMatterActivationRequest {
        let draft = HoloContextPlanDraft(
            runID: "run-1",
            draftRevision: 1,
            goalSummary: "国庆日本旅行准备",
            answerText: "回答",
            items: [],
            unknowns: unknowns.map { unknown in
                HoloContextPlanUnknown(
                    question: unknown,
                    impact: "影响安排",
                    independentParts: ""
                )
            }
        )
        return HoloMatterActivationRequest(
            draft: draft,
            contextPlanMessageID: messageID,
            confirmedTitle: title,
            confirmedTargetDate: targetDate,
            existingMatterID: existingMatterID
        )
    }

    // MARK: - 激活

    func testActivationCreatesActiveMatterWithOriginLinkAndSuggestedLoops() async throws {
        let messageID = UUID()
        let receipt = try await repo.activateMatter(request: makeRequest(messageID: messageID))

        XCTAssertTrue(receipt.created)
        let matter = try XCTUnwrap(repo.matter(id: receipt.matterID))
        XCTAssertEqual(matter.lifecycle, .active)
        XCTAssertEqual(matter.phase, .planning)
        XCTAssertEqual(matter.title, "国庆日本旅行")
        XCTAssertEqual(matter.origin, .contextPlan)
        // 方案卡 origin link 必须存在
        let originLinks = repo.links(matterID: matter.id).filter { $0.role == .origin }
        XCTAssertEqual(originLinks.count, 1)
        XCTAssertEqual(originLinks.first?.entityID, messageID.uuidString)
        // unknowns → suggested（不 confirmed）
        let loops = repo.openLoops(matterID: matter.id)
        XCTAssertEqual(loops.count, 2)
        XCTAssertTrue(loops.allSatisfy { $0.epistemic == .suggested })
        XCTAssertTrue(loops.allSatisfy { $0.state == .open })
    }

    /// 方案红线：同一来源重复点击开始整理，不得创建第二个 Matter。
    func testActivationIsIdempotentPerSourceMessage() async throws {
        let messageID = UUID()
        let first = try await repo.activateMatter(request: makeRequest(messageID: messageID))
        let second = try await repo.activateMatter(request: makeRequest(messageID: messageID))

        XCTAssertFalse(second.created)
        XCTAssertEqual(first.matterID, second.matterID)

        let request = NSFetchRequest<HoloMatter>(entityName: "HoloMatter")
        XCTAssertEqual(try context.fetch(request).count, 1, "重复激活创建了副本")
    }

    /// 方案 §3.1：只有真正的未知问题转 suggested，不把所有建议清单复制成问题。
    func testActivationDoesNotCopyPlanItemsAsLoops() async throws {
        // unknowns 为空 → 不产生 loop
        let receipt = try await repo.activateMatter(request: makeRequest(unknowns: []))
        XCTAssertEqual(repo.openLoops(matterID: receipt.matterID).count, 0)
    }

    /// 用户选择「更新到已有」：不新建，补 origin link。
    func testActivationUpdatesExistingMatterWhenUserChooses() async throws {
        let originalMessageID = UUID()
        let original = try await repo.activateMatter(request: makeRequest(messageID: originalMessageID))

        let newMessageID = UUID()
        let updated = try await repo.activateMatter(
            request: makeRequest(messageID: newMessageID, unknowns: [], existingMatterID: original.matterID)
        )

        XCTAssertFalse(updated.created)
        XCTAssertEqual(updated.matterID, original.matterID)
        let request = NSFetchRequest<HoloMatter>(entityName: "HoloMatter")
        XCTAssertEqual(try context.fetch(request).count, 1, "更新到已有时不应新建")
        // 新来源的 origin link 挂到原 Matter
        let newOriginLinks = repo.links(matterID: original.matterID).filter {
            $0.role == .origin && $0.entityID == newMessageID.uuidString
        }
        XCTAssertEqual(newOriginLinks.count, 1)
    }

    // MARK: - 生命周期

    func testCompleteArchiveReopenLifecycle() async throws {
        let receipt = try await repo.activateMatter(request: makeRequest())
        let id = receipt.matterID

        try await repo.completeMatter(id: id)
        XCTAssertEqual(repo.matter(id: id)?.lifecycle, .completed)
        XCTAssertNotNil(repo.matter(id: id)?.completedAt)

        try await repo.archiveMatter(id: id)
        XCTAssertEqual(repo.matter(id: id)?.lifecycle, .archived)

        try await repo.reopenMatter(id: id)
        XCTAssertEqual(repo.matter(id: id)?.lifecycle, .active)
        XCTAssertNil(repo.matter(id: id)?.completedAt)
    }

    func testIllegalTransitionThrows() async throws {
        let receipt = try await repo.activateMatter(request: makeRequest())
        // active → dismissed 非法（dismiss 是 candidate 专属）；
        // active → archived 已于 2026-09-21 合法化（详情菜单提供轻性收起入口）。
        do {
            try await repo.dismissCandidate(id: receipt.matterID)
            XCTFail("active→dismissed 应被拒绝")
        } catch {
            // 预期：非法迁移被拒
        }
        // 状态未被破坏
        XCTAssertEqual(repo.matter(id: receipt.matterID)?.lifecycle, .active)
    }

    // MARK: - Open Loop

    func testConfirmSuggestedOpenLoop() async throws {
        let receipt = try await repo.activateMatter(request: makeRequest())
        let loop = try XCTUnwrap(repo.openLoops(matterID: receipt.matterID).first)

        try await repo.confirmOpenLoop(id: loop.id)
        XCTAssertEqual(repo.openLoops(matterID: receipt.matterID).first?.epistemic, .confirmed)
    }

    /// 方案 §10.3：AI proposal 永远不能把已解决项重新打开。
    func testAssistantCannotReopenResolvedLoop() async throws {
        let receipt = try await repo.activateMatter(request: makeRequest())
        let loop = try XCTUnwrap(repo.openLoops(matterID: receipt.matterID).first)

        try await repo.setOpenLoopState(id: loop.id, state: .resolved, actor: .assistant, sourceRevision: "1")

        do {
            try await repo.setOpenLoopState(id: loop.id, state: .open, actor: .assistant, sourceRevision: "2")
            XCTFail("assistant 复活已解决项应被拒绝")
        } catch let error as HoloMatterRepositoryError {
            guard case .assistantActionNotAllowed = error else {
                return XCTFail("错误的错误类型：\(error)")
            }
        }
        XCTAssertEqual(repo.openLoops(matterID: receipt.matterID).first?.state, .resolved)
    }

    func testAssistantAutoResolveIsIdempotentPerSourceRevision() async throws {
        let receipt = try await repo.activateMatter(request: makeRequest())
        let loop = try XCTUnwrap(repo.openLoops(matterID: receipt.matterID).first)

        try await repo.setOpenLoopState(id: loop.id, state: .resolved, actor: .assistant, sourceRevision: "msg-1")
        // 同一 sourceRevision 重试（网络重发）→ 幂等，事件不重复
        try await repo.setOpenLoopState(id: loop.id, state: .resolved, actor: .assistant, sourceRevision: "msg-1")

        let events = repo.events(matterID: receipt.matterID).filter { $0.kind == .openLoopResolved }
        XCTAssertEqual(events.count, 1, "重复 resolve 产生了重复事件")
    }

    // MARK: - Link

    func testLinkAddIsIdempotent() async throws {
        let receipt = try await repo.activateMatter(request: makeRequest(unknowns: []))
        let thoughtID = "thought-abc"

        _ = try await repo.addLink(matterID: receipt.matterID, entityType: .thought, entityID: thoughtID, role: .resource, origin: .explicit)
        _ = try await repo.addLink(matterID: receipt.matterID, entityType: .thought, entityID: thoughtID, role: .resource, origin: .explicit)

        let links = repo.links(matterID: receipt.matterID).filter { $0.entityID == thoughtID }
        XCTAssertEqual(links.count, 1, "重复链接产生副本")
    }

    func testRejectLinkKeepsSuppression() async throws {
        let receipt = try await repo.activateMatter(request: makeRequest(unknowns: []))
        let link = try await repo.rejectLink(matterID: receipt.matterID, entityType: .thought, entityID: "unrelated")

        XCTAssertEqual(link.status, .rejected)
        // 被拒链接不算 linked（激活自带的 origin link 不计入 thought 过滤）
        let linkedThoughts = repo.links(matterID: receipt.matterID, linkedOnly: true).filter { $0.entityType == .thought }
        XCTAssertEqual(linkedThoughts.count, 0)
        // suppression 记录仍在（防止反复建议同一内容）
        let allThoughts = repo.links(matterID: receipt.matterID, linkedOnly: false).filter { $0.entityType == .thought }
        XCTAssertEqual(allThoughts.count, 1)
        XCTAssertEqual(allThoughts.first?.status, .rejected)
    }

    // MARK: - 撤销

    /// 方案 §6.1：自动更新必须可撤销，撤销通过反向事件，不抹审计记录。
    func testRevertResolvedLoopRestoresOpenState() async throws {
        let receipt = try await repo.activateMatter(request: makeRequest())
        let loop = try XCTUnwrap(repo.openLoops(matterID: receipt.matterID).first)

        try await repo.setOpenLoopState(id: loop.id, state: .resolved, actor: .assistant, sourceRevision: "msg-9")
        let resolveEvent = try XCTUnwrap(
            repo.events(matterID: receipt.matterID).first { $0.kind == .openLoopResolved }
        )

        try await repo.revertEvent(eventID: resolveEvent.id)

        XCTAssertEqual(repo.openLoops(matterID: receipt.matterID).first?.state, .open)
        // 反向事件存在且指回原事件；原事件仍在（审计不消失）
        let revertEvent = try XCTUnwrap(
            repo.events(matterID: receipt.matterID).first { $0.revertsEventID == resolveEvent.id }
        )
        XCTAssertEqual(revertEvent.kind, .reverted)
        XCTAssertTrue(repo.events(matterID: receipt.matterID).contains { $0.id == resolveEvent.id })
    }

    func testRevertIsIdempotent() async throws {
        let receipt = try await repo.activateMatter(request: makeRequest())
        let loop = try XCTUnwrap(repo.openLoops(matterID: receipt.matterID).first)

        try await repo.setOpenLoopState(id: loop.id, state: .resolved, actor: .assistant, sourceRevision: "msg-9")
        let resolveEvent = try XCTUnwrap(
            repo.events(matterID: receipt.matterID).first { $0.kind == .openLoopResolved }
        )

        try await repo.revertEvent(eventID: resolveEvent.id)
        try await repo.revertEvent(eventID: resolveEvent.id)  // 重复撤销不崩不重复

        let revertEvents = repo.events(matterID: receipt.matterID).filter { $0.revertsEventID == resolveEvent.id }
        XCTAssertEqual(revertEvents.count, 1)
    }

    // MARK: - revision 语义

    /// canonical mutation 递增 revision；投影未跟上时判定 stale。
    func testRevisionBumpsAndProjectionStaleness() async throws {
        let receipt = try await repo.activateMatter(request: makeRequest())
        let id = receipt.matterID
        let revisionAfterActivation = repo.matter(id: id)!.revision

        let loop = try XCTUnwrap(repo.openLoops(matterID: id).first)
        try await repo.confirmOpenLoop(id: loop.id)

        let matter = try XCTUnwrap(repo.matter(id: id))
        XCTAssertGreaterThan(matter.revision, revisionAfterActivation, "canonical 变更未递增 revision")

        // 旧 revision 的投影必须被判 stale
        let staleProjection = HoloMatterProjectionV1(
            matterID: id,
            sourceMatterRevision: revisionAfterActivation,
            summary: "旧判断",
            attention: .onTrack,
            generatedAt: fixedNow
        )
        matter.projection = staleProjection
        XCTAssertTrue(matter.isProjectionStale)
    }
}

// MARK: - 计划修订（2026-09-23 addTask 提案 → 确认落库 → 撤销）

@MainActor
final class HoloMatterPlanAmendmentTests: XCTestCase {

    private static let sharedContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "HoloMatterPlanAmendmentTests", managedObjectModel: CoreDataTestSupport.sharedModel)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        try? container.loadPersistentStores { _, _ in }
        return container
    }()

    private var context: NSManagedObjectContext!
    private var repo: HoloMatterRepository!
    private let fixedNow = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUp() async throws {
        context = Self.sharedContainer.viewContext
        try CoreDataTestSupport.clearAllEntities(context)
        repo = HoloMatterRepository(context: context, clock: { self.fixedNow })
    }

    /// 建一个带 7 步计划的事项（launchPlan 主路径）。
    private func launchJapanPlan() async throws -> HoloMatterPlanLaunchReceipt {
        let draft = HoloContextPlanDraft(
            runID: "run-amend",
            draftRevision: 1,
            goalSummary: "国庆日本旅行",
            answerText: "准备",
            items: (0..<7).map { HoloContextPlanItem(itemID: "i-\($0)", title: "步骤\($0)", kind: .task) }
        )
        return try await repo.launchPlan(request: HoloMatterPlanLaunchRequest(
            contextPlanMessageID: UUID(),
            draft: draft,
            confirmedTitle: "国庆日本旅行"
        ))
    }

    func testAppendTaskToPlanAppendsAtEnd() async throws {
        let receipt = try await launchJapanPlan()
        let revisionBefore = repo.matter(id: receipt.matterID)?.revision ?? 0

        let result = try await repo.appendTaskToPlan(
            matterID: receipt.matterID, title: "确定深圳到香港的交通", note: "蛇口船或陆路口岸",
            sourceProposalID: "p-test-1"
        )

        XCTAssertEqual(result.planOrder, 7, "新任务必须接在计划末尾")
        let plan = MatterPlanQuery.planTasks(matterID: receipt.matterID, repository: repo)
        XCTAssertEqual(plan.count, 8)
        XCTAssertEqual(plan.last?.id, result.taskID)
        XCTAssertEqual(plan.last?.title, "确定深圳到香港的交通")
        // 任务挂主题清单
        let task = repo.todoTask(id: result.taskID)
        XCTAssertEqual(task?.list?.id, receipt.listID)
        // revision + 事件
        XCTAssertEqual(repo.matter(id: receipt.matterID)?.revision, revisionBefore + 1)
        let events = repo.events(matterID: receipt.matterID, limit: 10)
        XCTAssertTrue(events.contains { $0.payload["kind"] == "addTask" && $0.payload["taskID"] == result.taskID.uuidString })
    }

    func testAppendTaskToPlanIsIdempotentPerProposal() async throws {
        let receipt = try await launchJapanPlan()
        let first = try await repo.appendTaskToPlan(
            matterID: receipt.matterID, title: "确定深圳到香港的交通", note: nil, sourceProposalID: "p-dup"
        )
        let second = try await repo.appendTaskToPlan(
            matterID: receipt.matterID, title: "确定深圳到香港的交通", note: nil, sourceProposalID: "p-dup"
        )
        XCTAssertEqual(first.taskID, second.taskID)
        XCTAssertEqual(first.planOrder, second.planOrder)
        XCTAssertEqual(MatterPlanQuery.planTasks(matterID: receipt.matterID, repository: repo).count, 8, "同一提案重复确认不重复落库")
    }

    func testAppendTaskToPlanWithoutPlanListThrows() async throws {
        let matter = try await repo.createManualMatter(title: "手工事项", targetDate: nil)
        do {
            _ = try await repo.appendTaskToPlan(
                matterID: matter.id, title: "任意任务", note: nil, sourceProposalID: "p-nolist"
            )
            XCTFail("无计划清单的事项不应支持追加")
        } catch {
            // 预期抛错
        }
    }

    func testRevertAddTaskSoftDeletesTaskAndUnlinks() async throws {
        let receipt = try await launchJapanPlan()
        let appended = try await repo.appendTaskToPlan(
            matterID: receipt.matterID, title: "确定深圳到香港的交通", note: nil, sourceProposalID: "p-revert"
        )
        let revisionAfterAppend = repo.matter(id: receipt.matterID)?.revision ?? 0

        try await repo.revertEvent(eventID: appended.eventID)

        // 任务软删（进回收站），计划查询排除
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", appended.taskID as CVarArg)
        let task = try XCTUnwrap((try? context.fetch(request))?.first)
        XCTAssertEqual(task.deletedFlag, true)
        XCTAssertNotNil(task.deletedAt)
        XCTAssertEqual(MatterPlanQuery.planTasks(matterID: receipt.matterID, repository: repo).count, 7, "撤销后计划回到 7 步")
        // revision 再 +1，反向事件已追加且幂等
        XCTAssertEqual(repo.matter(id: receipt.matterID)?.revision, revisionAfterAppend + 1)
        try await repo.revertEvent(eventID: appended.eventID)
        XCTAssertEqual(repo.matter(id: receipt.matterID)?.revision, revisionAfterAppend + 1, "重复撤销幂等")
    }

    func testValidatorRejectsDuplicatePlanTaskTitle() {
        let context = HoloMatterMutationValidator.Context(
            matterID: UUID(), currentRevision: 3, knownOpenLoopIDs: [],
            planTaskTitles: [HoloMatterMutationValidator.normalizedPlanTitle("确定深圳到香港的交通")]
        )
        var proposal = HoloMatterMutationProposal(
            proposalID: "p-v", matterID: context.matterID, baseMatterRevision: 3
        )
        proposal.mutations = [.addTask(HoloMatterTaskDraft(title: "确定深圳到香港的交通"))]
        if case .rejected = HoloMatterMutationValidator.validate(proposal, context: context) {} else {
            XCTFail("重复标题应被拒绝")
        }
        proposal.mutations = [.addTask(HoloMatterTaskDraft(title: "  确定深圳到香港的交通  "))]
        if case .rejected = HoloMatterMutationValidator.validate(proposal, context: context) {} else {
            XCTFail("仅空白差异的同名任务应被拒绝")
        }
    }

    func testPolicyRequiresConfirmationForAddTask() {
        let context = HoloMatterMutationValidator.Context(matterID: UUID(), currentRevision: 1, knownOpenLoopIDs: [])
        var proposal = HoloMatterMutationProposal(
            proposalID: "p-policy", matterID: context.matterID, baseMatterRevision: 1
        )
        proposal.mutations = [.addTask(HoloMatterTaskDraft(title: "新步骤"))]
        XCTAssertEqual(
            HoloMatterMutationPolicy.decide(proposal, context: context),
            .needsConfirmation,
            "addTask 恒需用户确认，模型不可直接落库"
        )
    }

    func testParserParsesAddTaskMutation() throws {
        let json = """
        {"proposalID":"p-1","matterID":"\(UUID().uuidString)","baseMatterRevision":2,
         "mutations":[{"kind":"addTask","title":"确定深圳到香港的交通","note":"蛇口船或陆路口岸"}]}
        """
        let proposal = try HoloMatterProposalParser.parse(json, matterID: UUID())
        guard case .addTask(let draft)? = proposal.mutations.first else {
            return XCTFail("应解析出 addTask")
        }
        XCTAssertEqual(draft.title, "确定深圳到香港的交通")
        XCTAssertEqual(draft.note, "蛇口船或陆路口岸")
    }
}

// MARK: - 上次上下文恢复（2026-09-23 幽灵条）

@MainActor
final class MatterContextRecoveryTests: XCTestCase {

    private static let sharedContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "MatterContextRecoveryTests", managedObjectModel: CoreDataTestSupport.sharedModel)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        try? container.loadPersistentStores { _, _ in }
        return container
    }()

    private var context: NSManagedObjectContext!
    private var repo: HoloMatterRepository!
    private var store: MatterChatContextStore!
    private var defaults: UserDefaults!
    private let fixedNow = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUp() async throws {
        context = Self.sharedContainer.viewContext
        try CoreDataTestSupport.clearAllEntities(context)
        repo = HoloMatterRepository(context: context, clock: { self.fixedNow })
        store = MatterChatContextStore.shared
        store.active = nil
        store.recoverableContext = nil
        store.pendingTaskProposal = nil
        defaults = UserDefaults(suiteName: "MatterContextRecoveryTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "holo_matter_recent_context_v1")
    }

    private func persistRecord(matterID: UUID, enteredAt: Date) {
        defaults.set([
            "matterID": matterID.uuidString,
            "enteredAt": enteredAt.timeIntervalSince1970
        ], forKey: "holo_matter_recent_context_v1")
    }

    private func makeActiveMatter() async throws -> HoloMatter {
        try await repo.createManualMatter(title: "国庆日本旅行", targetDate: nil)
    }

    func testLoadRecoversWithinWindow() async throws {
        let matter = try await makeActiveMatter()
        persistRecord(matterID: matter.id, enteredAt: fixedNow.addingTimeInterval(-3_600))

        store.loadRecoverableIfAny(defaults: defaults, now: fixedNow, repository: repo)

        XCTAssertEqual(store.recoverableContext?.matterID, matter.id)
        XCTAssertEqual(store.recoverableContext?.title, "国庆日本旅行")
        XCTAssertNil(store.active, "恢复提示不自动挂载上下文")
    }

    func testLoadIgnoresRecordOutsideWindow() async throws {
        let matter = try await makeActiveMatter()
        persistRecord(matterID: matter.id, enteredAt: fixedNow.addingTimeInterval(-25 * 3_600))

        store.loadRecoverableIfAny(defaults: defaults, now: fixedNow, repository: repo)

        XCTAssertNil(store.recoverableContext)
        XCTAssertNil(defaults.dictionary(forKey: "holo_matter_recent_context_v1"), "过期记录应清除")
    }

    func testLoadIgnoresCompletedMatter() async throws {
        let matter = try await makeActiveMatter()
        try await repo.completeMatter(id: matter.id)
        persistRecord(matterID: matter.id, enteredAt: fixedNow.addingTimeInterval(-3_600))

        store.loadRecoverableIfAny(defaults: defaults, now: fixedNow, repository: repo)

        XCTAssertNil(store.recoverableContext, "已完成事项不再提示恢复")
    }

    func testRestoreActivatesContextWithRestoredSource() async throws {
        let matter = try await makeActiveMatter()
        persistRecord(matterID: matter.id, enteredAt: fixedNow.addingTimeInterval(-3_600))
        store.loadRecoverableIfAny(defaults: defaults, now: fixedNow, repository: repo)

        store.restoreRecoverable()

        XCTAssertEqual(store.active?.matterID, matter.id)
        XCTAssertEqual(store.active?.source, .restored)
        XCTAssertNil(store.recoverableContext)
    }

    func testDismissClearsPersistedRecord() async throws {
        let matter = try await makeActiveMatter()
        persistRecord(matterID: matter.id, enteredAt: fixedNow.addingTimeInterval(-3_600))
        store.loadRecoverableIfAny(defaults: defaults, now: fixedNow, repository: repo)

        store.dismissRecoverable(defaults: defaults)

        XCTAssertNil(store.recoverableContext)
        XCTAssertNil(defaults.dictionary(forKey: "holo_matter_recent_context_v1"))
    }
}
