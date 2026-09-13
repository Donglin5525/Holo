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
        // active → archived 非法（必须先 completed）
        do {
            try await repo.archiveMatter(id: receipt.matterID)
            XCTFail("active→archived 应被拒绝")
        } catch let error as HoloMatterRepositoryError {
            XCTAssertEqual(error, .illegalLifecycleTransition(from: "active", to: "archived"))
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
