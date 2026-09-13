//
//  HoloMatterRepository.swift
//  Holo
//
//  Matter「进行中的事」唯一写入口
//
//  方案 §10 契约：
//  - View / ViewModel / Prompt parser 不得直接操作 Matter 相关 NSManagedObjectContext
//  - 一次用户动作在同一 context 中原子完成：重读 revision → 校验 → 写 → revision+1 → 追加 Event → save
//  - 幂等：同一 idempotencyKey 重复请求折叠为同一结果，不产生副本
//  - 冲突优先级：用户显式 > 业务回执 > 系统确定性 > 模型推断；AI 永远不能把已解决项重新打开
//

import Foundation
import CoreData
import Combine
import os.log

// MARK: - 错误

nonisolated enum HoloMatterRepositoryError: Error, Equatable, Sendable {
    /// 生命周期迁移不合法（如系统试图自动完成）。
    case illegalLifecycleTransition(from: String, to: String)
    /// 指定的 Matter / Open Loop / Event 不存在。
    case notFound(String)
    /// AI 试图执行越权状态变更（如把 resolved 改回 open）。
    case assistantActionNotAllowed(String)
    /// 标题不合法（空、超长）。
    case invalidTitle
}

// MARK: - Repository

@MainActor
final class HoloMatterRepository: ObservableObject {

    /// 生产单例：与项目其余 Repository 一致使用 viewContext（CloudKit 合并、UI 观察均建立在它之上）。
    /// 所有写操作经 context.perform 原子执行（方案 §10.1 的单写者 + 事务语义）。
    static let shared = HoloMatterRepository(context: CoreDataStack.shared.viewContext)

    private let logger = Logger(subsystem: "com.holo.app", category: "HoloMatterRepository")

    /// 全部读写都在这一个 context 上串行执行，保证事务原子性与单写者语义。
    let context: NSManagedObjectContext

    /// 可注入时钟（测试时间语义）。
    private let clock: () -> Date

    /// 数据变化信号（UI 刷新用；CloudKit 导入的远程变更也会汇到这里）。
    @Published private(set) var changeToken: Int = 0

    init(context: NSManagedObjectContext, clock: @escaping () -> Date = { Date() }) {
        self.context = context
        self.clock = clock
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - 查询

    /// 按生命周期查询（排除软删除）。candidate 不对列表暴露（方案 §13.3）。
    func matters(lifecycles: [HoloMatterLifecycleStatus]) -> [HoloMatter] {
        let request = NSFetchRequest<HoloMatter>(entityName: "HoloMatter")
        request.predicate = NSPredicate(
            format: "deletedAt == nil AND lifecycleRaw IN %@",
            lifecycles.map(\.rawValue)
        )
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    func matter(id: UUID) -> HoloMatter? {
        let request = NSFetchRequest<HoloMatter>(entityName: "HoloMatter")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    func openLoops(matterID: UUID, activeOnly: Bool = false) -> [HoloMatterOpenLoop] {
        let request = NSFetchRequest<HoloMatterOpenLoop>(entityName: "HoloMatterOpenLoop")
        if activeOnly {
            request.predicate = NSPredicate(
                format: "matterID == %@ AND deletedAt == nil AND stateRaw IN %@",
                matterID as CVarArg,
                [HoloMatterOpenLoopState.open.rawValue, HoloMatterOpenLoopState.waiting.rawValue]
            )
        } else {
            request.predicate = NSPredicate(format: "matterID == %@ AND deletedAt == nil", matterID as CVarArg)
        }
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    func links(matterID: UUID, linkedOnly: Bool = true) -> [HoloMatterLink] {
        let request = NSFetchRequest<HoloMatterLink>(entityName: "HoloMatterLink")
        if linkedOnly {
            request.predicate = NSPredicate(
                format: "matterID == %@ AND deletedAt == nil AND statusRaw == %@",
                matterID as CVarArg,
                HoloMatterLinkStatus.linked.rawValue
            )
        } else {
            request.predicate = NSPredicate(format: "matterID == %@ AND deletedAt == nil", matterID as CVarArg)
        }
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    func events(matterID: UUID, limit: Int = 50) -> [HoloMatterEvent] {
        let request = NSFetchRequest<HoloMatterEvent>(entityName: "HoloMatterEvent")
        request.predicate = NSPredicate(format: "matterID == %@ AND deletedAt == nil", matterID as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchLimit = limit
        return (try? context.fetch(request)) ?? []
    }

    // MARK: - 手动创建（用户主动入口，方案 §11.1-2）

    /// Demo 清场（仅 -MatterDemoSeed 调用）：软删全部 Matter 数据，保证合成走查可重复。
    func deleteAllMattersForDemo() async throws {
        try await perform { ctx in
            for entityName in ["HoloMatter", "HoloMatterOpenLoop", "HoloMatterLink", "HoloMatterEvent"] {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                for object in (try? ctx.fetch(request)) ?? [] {
                    ctx.delete(object)
                }
            }
        }
    }

    /// 用户主动建立一件进行中的事（不经 Context Plan）。origin=manual。
    func createManualMatter(title: String, targetDate: Date?) async throws -> HoloMatter {
        let now = clock()
        return try await perform { ctx in
            let matter = HoloMatter(entity: NSEntityDescription.entity(forEntityName: "HoloMatter", in: ctx)!, insertInto: ctx)
            matter.id = UUID()
            matter.schemaVersion = 1
            matter.title = Self.sanitizedTitle(title)
            matter.lifecycle = .active
            matter.phase = .planning
            matter.targetDate = targetDate
            matter.origin = .manual
            matter.revision = 1
            matter.createdAt = now
            matter.updatedAt = now
            _ = try Self.appendEvent(
                matter: matter,
                idempotencyKey: "manual:\(matter.id.uuidString)",
                kind: .activated,
                actor: .user,
                payload: ["title": matter.title],
                sourceType: nil,
                sourceEntityID: nil,
                at: now,
                in: ctx
            )
            return matter
        }
    }

    // MARK: - 激活（幂等，M1 主入口）

    /// 从已校验的 Context Plan 草案激活 Matter。
    ///
    /// 幂等规则（方案 §9.4）：同一 contextPlanMessageID 重复调用返回同一 Matter 的 receipt（created=false）。
    /// 用户选择「更新到已有」时（existingMatterID 非空），只追加 origin link 与事件，不新建。
    func activateMatter(request: HoloMatterActivationRequest) async throws -> HoloMatterActivationReceipt {
        let now = clock()
        return try await perform { ctx in
            // 幂等闸门 1：同一来源消息已激活过 → 直接回原 receipt。
            if let existing = try Self.findMatterByOriginLink(
                contextPlanMessageID: request.contextPlanMessageID,
                in: ctx
            ) {
                return Self.makeReceipt(for: existing, created: false, at: now)
            }

            // 用户选择更新到已有 Matter：补 origin link + 事件，不新建。
            if let existingID = request.existingMatterID,
               let existing = try Self.fetchMatter(id: existingID, in: ctx) {
                let link = try Self.addLinkInternal(
                    matter: existing,
                    entityType: .contextPlan,
                    entityID: request.contextPlanMessageID.uuidString,
                    role: .origin,
                    origin: .system,
                    confidence: 1,
                    status: .linked,
                    sourceRevision: nil,
                    at: now,
                    in: ctx
                )
                Self.bumpRevision(of: existing, at: now)
                let event = try Self.appendEvent(
                    matter: existing,
                    idempotencyKey: HoloMatterIdempotencyKey.activate(contextPlanMessageID: request.contextPlanMessageID),
                    kind: .linkAdded,
                    actor: .user,
                    payload: ["entityType": HoloMatterLinkEntityType.contextPlan.rawValue, "entityID": link.entityID],
                    sourceType: HoloMatterLinkEntityType.contextPlan.rawValue,
                    sourceEntityID: request.contextPlanMessageID.uuidString,
                    at: now,
                    in: ctx
                )
                return HoloMatterActivationReceipt(
                    matterID: existing.id,
                    created: false,
                    linkedEntityIDs: [link.entityID],
                    suggestedOpenLoopIDs: [],
                    eventID: event.id
                )
            }

            // 新建 Matter：用户在确认弹层点了确认 = 显式激活，直接 active。
            let matter = HoloMatter(entity: NSEntityDescription.entity(forEntityName: "HoloMatter", in: ctx)!, insertInto: ctx)
            matter.id = UUID()
            matter.schemaVersion = 1
            matter.title = Self.sanitizedTitle(request.confirmedTitle)
            matter.lifecycle = .active
            matter.phase = .planning
            matter.startDate = nil
            matter.targetDate = request.confirmedTargetDate
            matter.origin = .contextPlan
            matter.originEntityID = request.contextPlanMessageID.uuidString
            matter.revision = 1
            matter.createdAt = now
            matter.updatedAt = now

            // 链接：origin（方案卡）+ 对话消息。
            var linkedIDs: [String] = []
            let originLink = try Self.addLinkInternal(
                matter: matter,
                entityType: .contextPlan,
                entityID: request.contextPlanMessageID.uuidString,
                role: .origin,
                origin: .system,
                confidence: 1,
                status: .linked,
                sourceRevision: "\(request.draft.draftRevision)",
                at: now,
                in: ctx
            )
            linkedIDs.append(originLink.entityID)

            if let userMessageID = request.userMessageID {
                let messageLink = try Self.addLinkInternal(
                    matter: matter,
                    entityType: .chatMessage,
                    entityID: userMessageID.uuidString,
                    role: .conversation,
                    origin: .system,
                    confidence: 1,
                    status: .linked,
                    sourceRevision: nil,
                    at: now,
                    in: ctx
                )
                linkedIDs.append(messageLink.entityID)
            }

            // Open Loop：只把真正的未知问题转 suggested（不复制全部建议清单）。
            var loopIDs: [UUID] = []
            for unknown in request.draft.unknowns {
                let loop = try Self.addOpenLoopInternal(
                    matter: matter,
                    logicalKey: Self.normalizeLogicalKey(unknown.question),
                    title: unknown.question,
                    epistemic: .suggested,
                    state: .open,
                    priority: .normal,
                    targetDate: nil,
                    sourceType: HoloMatterLinkEntityType.contextPlan.rawValue,
                    sourceEntityID: request.contextPlanMessageID.uuidString,
                    sourceRevision: Int64(request.draft.draftRevision),
                    at: now,
                    in: ctx
                )
                loopIDs.append(loop.id)
            }

            let event = try Self.appendEvent(
                matter: matter,
                idempotencyKey: HoloMatterIdempotencyKey.activate(contextPlanMessageID: request.contextPlanMessageID),
                kind: .activated,
                actor: .user,
                payload: ["title": matter.title],
                sourceType: HoloMatterLinkEntityType.contextPlan.rawValue,
                sourceEntityID: request.contextPlanMessageID.uuidString,
                at: now,
                in: ctx
            )

            return HoloMatterActivationReceipt(
                matterID: matter.id,
                created: true,
                linkedEntityIDs: linkedIDs,
                suggestedOpenLoopIDs: loopIDs,
                eventID: event.id
            )
        }
    }

    /// 去重预检（方案 §11.3）：命中同一来源消息的既有 Matter，供 UI 在确认前提示。
    func findMatterActivated(from contextPlanMessageID: UUID) -> HoloMatter? {
        let found: HoloMatter?? = performAndWait { ctx in
            try? Self.findMatterByOriginLink(contextPlanMessageID: contextPlanMessageID, in: ctx)
        }
        return found ?? nil
    }

    // MARK: - 生命周期（必须用户显式触发）

    func completeMatter(id: UUID) async throws {
        try await transitionLifecycle(id: id, to: .completed) { matter, now in
            matter.completedAt = now
            matter.archivedAt = nil
        }
    }

    func archiveMatter(id: UUID) async throws {
        try await transitionLifecycle(id: id, to: .archived) { matter, now in
            matter.archivedAt = now
        }
    }

    func reopenMatter(id: UUID) async throws {
        try await transitionLifecycle(id: id, to: .active) { matter, _ in
            matter.completedAt = nil
            matter.archivedAt = nil
        }
    }

    func dismissCandidate(id: UUID) async throws {
        try await transitionLifecycle(id: id, to: .dismissed) { _, _ in }
    }

    private func transitionLifecycle(
        id: UUID,
        to target: HoloMatterLifecycleStatus,
        mutate: @escaping (HoloMatter, Date) -> Void
    ) async throws {
        let now = clock()
        return try await perform { ctx in
            guard let matter = try Self.fetchMatter(id: id, in: ctx) else {
                throw HoloMatterRepositoryError.notFound("HoloMatter \(id)")
            }
            let current = matter.lifecycle
            guard current.canTransition(to: target) else {
                throw HoloMatterRepositoryError.illegalLifecycleTransition(from: current.rawValue, to: target.rawValue)
            }
            matter.lifecycle = target
            mutate(matter, now)
            Self.bumpRevision(of: matter, at: now)
            let kind: HoloMatterEventKind
            switch target {
            case .completed: kind = .completed
            case .archived: kind = .archived
            case .active: kind = .reopened
            case .dismissed, .candidate: kind = .reverted
            }
            _ = try Self.appendEvent(
                matter: matter,
                idempotencyKey: Self.lifecycleEventKey(matterID: id, to: target, revision: matter.revision),
                kind: kind,
                actor: .user,
                payload: ["from": current.rawValue, "to": target.rawValue],
                sourceType: nil,
                sourceEntityID: nil,
                at: now,
                in: ctx
            )
        }
    }

    // MARK: - Open Loop 操作

    /// 新增 AI 建议的问题（落库恒 suggested；同 logicalKey 幂等去重）。
    @discardableResult
    func addSuggestedOpenLoop(matterID: UUID, draft: HoloMatterOpenLoopDraft) async throws -> HoloMatterOpenLoop {
        let now = clock()
        return try await perform { ctx in
            guard let matter = try Self.fetchMatter(id: matterID, in: ctx) else {
                throw HoloMatterRepositoryError.notFound("HoloMatter \(matterID)")
            }
            let loop = try Self.addOpenLoopInternal(
                matter: matter,
                logicalKey: draft.logicalKey.isEmpty ? Self.normalizeLogicalKey(draft.title) : draft.logicalKey,
                title: draft.title,
                epistemic: .suggested,
                state: .open,
                priority: draft.priority,
                targetDate: draft.targetDate,
                sourceType: "assistant",
                sourceEntityID: nil,
                sourceRevision: matter.revision,
                at: now,
                in: ctx
            )
            if loop.createdAt == now {
                Self.bumpRevision(of: matter, at: now)
                _ = try Self.appendEvent(
                    matter: matter,
                    idempotencyKey: "loop:\(matter.id.uuidString):\(loop.logicalKey):\(matter.revision)",
                    kind: .openLoopAdded,
                    actor: .assistant,
                    payload: ["openLoopID": loop.id.uuidString, "title": loop.title],
                    sourceType: nil,
                    sourceEntityID: nil,
                    at: now,
                    in: ctx
                )
            }
            return loop
        }
    }

    /// 用户确认 AI 建议的问题（suggested → confirmed）。需要一次显式确认动作，模型不可调用。
    func confirmOpenLoop(id: UUID) async throws {        let now = clock()
        try await perform { ctx in
            guard let loop = try Self.fetchOpenLoop(id: id, in: ctx) else {
                throw HoloMatterRepositoryError.notFound("HoloMatterOpenLoop \(id)")
            }
            guard let matter = try Self.fetchMatter(id: loop.matterID, in: ctx) else {
                throw HoloMatterRepositoryError.notFound("HoloMatter \(loop.matterID)")
            }
            guard loop.epistemic == .suggested else { return }
            loop.epistemic = .confirmed
            loop.revision += 1
            loop.updatedAt = now
            Self.bumpRevision(of: matter, at: now)
            _ = try Self.appendEvent(
                matter: matter,
                idempotencyKey: "confirm:\(matter.id.uuidString):\(loop.id.uuidString):\(loop.revision)",
                kind: .openLoopConfirmed,
                actor: .user,
                payload: ["openLoopID": loop.id.uuidString, "title": loop.title],
                sourceType: loop.sourceTypeRaw,
                sourceEntityID: loop.sourceEntityID,
                at: now,
                in: ctx
            )
        }
    }

    /// 用户表态「不需要处理」（→ dismissed）。
    func dismissOpenLoop(id: UUID, actor: HoloMatterActor) async throws {
        let now = clock()
        try await perform { ctx in
            guard let loop = try Self.fetchOpenLoop(id: id, in: ctx) else {
                throw HoloMatterRepositoryError.notFound("HoloMatterOpenLoop \(id)")
            }
            guard let matter = try Self.fetchMatter(id: loop.matterID, in: ctx) else {
                throw HoloMatterRepositoryError.notFound("HoloMatter \(loop.matterID)")
            }
            guard loop.state != .resolved else {
                throw HoloMatterRepositoryError.assistantActionNotAllowed("不能 dismissed 已 resolved 的 Open Loop")
            }
            loop.state = .dismissed
            loop.revision += 1
            loop.updatedAt = now
            Self.bumpRevision(of: matter, at: now)
            _ = try Self.appendEvent(
                matter: matter,
                idempotencyKey: "dismiss:\(matter.id.uuidString):\(loop.id.uuidString):\(loop.revision)",
                kind: .openLoopDismissed,
                actor: actor,
                payload: ["openLoopID": loop.id.uuidString, "title": loop.title],
                sourceType: loop.sourceTypeRaw,
                sourceEntityID: loop.sourceEntityID,
                at: now,
                in: ctx
            )
        }
    }

    /// 更新 Open Loop 状态。
    ///
    /// 自动应用约束（方案 §11.5/§10.3）：
    /// - assistant 不得把 resolved / dismissed 改回 open（不能复活已解决项）
    /// - assistant 只能表达明确语义：open → resolved / waiting
    /// - 同 sourceRevision 的 resolve 重复请求幂等折叠
    func setOpenLoopState(
        id: UUID,
        state: HoloMatterOpenLoopState,
        actor: HoloMatterActor,
        sourceRevision: String = "0",
        sourceType: String? = nil,
        sourceEntityID: String? = nil
    ) async throws {
        let now = clock()
        try await perform { ctx in
            guard let loop = try Self.fetchOpenLoop(id: id, in: ctx) else {
                throw HoloMatterRepositoryError.notFound("HoloMatterOpenLoop \(id)")
            }
            guard let matter = try Self.fetchMatter(id: loop.matterID, in: ctx) else {
                throw HoloMatterRepositoryError.notFound("HoloMatter \(loop.matterID)")
            }

            if actor == .assistant {
                guard loop.state == .open || state == loop.state else {
                    throw HoloMatterRepositoryError.assistantActionNotAllowed(
                        "assistant 不可把 \(loop.state.rawValue) 改为 \(state.rawValue)"
                    )
                }
            }
            guard loop.state != state else { return }

            let from = loop.state
            loop.state = state
            loop.revision += 1
            loop.updatedAt = now
            if let sourceType { loop.sourceTypeRaw = sourceType }
            if let sourceEntityID { loop.sourceEntityID = sourceEntityID }
            Self.bumpRevision(of: matter, at: now)

            _ = try Self.appendEvent(
                matter: matter,
                idempotencyKey: HoloMatterIdempotencyKey.resolve(
                    matterID: matter.id, openLoopID: loop.id, sourceRevision: sourceRevision
                ),
                kind: (state == .resolved) ? .openLoopResolved : .reverted,
                actor: actor,
                payload: ["openLoopID": loop.id.uuidString, "title": loop.title, "from": from.rawValue, "to": state.rawValue],
                sourceType: sourceType ?? loop.sourceTypeRaw,
                sourceEntityID: sourceEntityID ?? loop.sourceEntityID,
                at: now,
                in: ctx
            )
        }
    }

    // MARK: - Link 操作

    /// 添加链接（幂等：同 matter+type+entityID 已存在则折叠）。
    @discardableResult
    func addLink(
        matterID: UUID,
        entityType: HoloMatterLinkEntityType,
        entityID: String,
        role: HoloMatterLinkRole,
        origin: HoloMatterLinkOrigin,
        confidence: Double = 1,
        status: HoloMatterLinkStatus = .linked,
        sourceRevision: String? = nil
    ) async throws -> HoloMatterLink {
        let now = clock()
        return try await perform { ctx in
            guard let matter = try Self.fetchMatter(id: matterID, in: ctx) else {
                throw HoloMatterRepositoryError.notFound("HoloMatter \(matterID)")
            }
            let link = try Self.addLinkInternal(
                matter: matter,
                entityType: entityType,
                entityID: entityID,
                role: role,
                origin: origin,
                confidence: confidence,
                status: status,
                sourceRevision: sourceRevision,
                at: now,
                in: ctx
            )
            if status == .linked {
                Self.bumpRevision(of: matter, at: now)
                _ = try Self.appendEvent(
                    matter: matter,
                    idempotencyKey: HoloMatterIdempotencyKey.link(matterID: matterID, entityType: entityType, entityID: entityID),
                    kind: .linkAdded,
                    actor: (origin == .explicit) ? .user : .system,
                    payload: ["entityType": entityType.rawValue, "entityID": entityID],
                    sourceType: entityType.rawValue,
                    sourceEntityID: entityID,
                    at: now,
                    in: ctx
                )
            }
            return link
        }
    }

    /// 用户表态「移出这件事」/「不属于这件事」。
    func removeLink(linkID: UUID) async throws {
        let now = clock()
        try await perform { ctx in
            let request = NSFetchRequest<HoloMatterLink>(entityName: "HoloMatterLink")
            request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", linkID as CVarArg)
            request.fetchLimit = 1
            guard let link = (try ctx.fetch(request)).first else {
                throw HoloMatterRepositoryError.notFound("HoloMatterLink \(linkID)")
            }
            guard let matter = try Self.fetchMatter(id: link.matterID, in: ctx) else {
                throw HoloMatterRepositoryError.notFound("HoloMatter \(link.matterID)")
            }
            link.status = .unlinked
            link.updatedAt = now
            Self.bumpRevision(of: matter, at: now)
            _ = try Self.appendEvent(
                matter: matter,
                idempotencyKey: "unlink:\(matter.id.uuidString):\(link.entityTypeRaw):\(link.entityID):\(matter.revision)",
                kind: .linkRemoved,
                actor: .user,
                payload: ["entityType": link.entityTypeRaw, "entityID": link.entityID],
                sourceType: link.entityTypeRaw,
                sourceEntityID: link.entityID,
                at: now,
                in: ctx
            )
        }
    }

    /// 推断类链接被用户拒绝：保留 suppression 记录（status=rejected），防止重复建议。
    @discardableResult
    func rejectLink(matterID: UUID, entityType: HoloMatterLinkEntityType, entityID: String) async throws -> HoloMatterLink {
        let now = clock()
        return try await perform { ctx in
            guard let matter = try Self.fetchMatter(id: matterID, in: ctx) else {
                throw HoloMatterRepositoryError.notFound("HoloMatter \(matterID)")
            }
            return try Self.addLinkInternal(
                matter: matter,
                entityType: entityType,
                entityID: entityID,
                role: .resource,
                origin: .inferred,
                confidence: 0,
                status: .rejected,
                sourceRevision: nil,
                at: now,
                in: ctx
            )
        }
    }

    // MARK: - 撤销（反向事件，不抹审计）

    /// 撤销一个自动更新事件（如 openLoopResolved）：回滚对应状态并写入带 revertsEventID 的反向事件。
    func revertEvent(eventID: UUID) async throws {
        let now = clock()
        try await perform { ctx in
            let request = NSFetchRequest<HoloMatterEvent>(entityName: "HoloMatterEvent")
            request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", eventID as CVarArg)
            request.fetchLimit = 1
            guard let event = (try ctx.fetch(request)).first else {
                throw HoloMatterRepositoryError.notFound("HoloMatterEvent \(eventID)")
            }
            guard let matter = try Self.fetchMatter(id: event.matterID, in: ctx) else {
                throw HoloMatterRepositoryError.notFound("HoloMatter \(event.matterID)")
            }

            // 已被撤销过 → 幂等返回。
            if try Self.eventAlreadyReverted(eventID: eventID, in: ctx) { return }

            switch event.kind {
            case .openLoopResolved:
                guard let loopIDString = event.payload["openLoopID"], let loopID = UUID(uuidString: loopIDString),
                      let loop = try Self.fetchOpenLoop(id: loopID, in: ctx) else {
                    throw HoloMatterRepositoryError.notFound("openLoop from event \(eventID)")
                }
                loop.state = .open
                loop.resolvedAt = nil
                loop.revision += 1
                loop.updatedAt = now
            default:
                throw HoloMatterRepositoryError.assistantActionNotAllowed("事件 \(event.kind.rawValue) 暂不支持撤销")
            }

            Self.bumpRevision(of: matter, at: now)
            _ = try Self.appendEvent(
                matter: matter,
                idempotencyKey: "revert:\(event.id.uuidString)",
                kind: .reverted,
                actor: .user,
                payload: ["reverts": event.kind.rawValue],
                sourceType: event.sourceTypeRaw,
                sourceEntityID: event.sourceEntityID,
                at: now,
                in: ctx,
                revertsEventID: event.id
            )
        }
    }

    // MARK: - 投影落盘（ProjectionBuilder 专用）

    func saveProjection(matterID: UUID, projection: HoloMatterProjectionV1) async throws {
        try await perform { ctx in
            guard let matter = try Self.fetchMatter(id: matterID, in: ctx) else {
                throw HoloMatterRepositoryError.notFound("HoloMatter \(matterID)")
            }
            matter.projection = projection
            matter.updatedAt = self.clock()
            // 投影刷新不递增 canonical revision：revision 只随事实变化。
            _ = try Self.appendEvent(
                matter: matter,
                idempotencyKey: "projection:\(matter.id.uuidString):\(projection.sourceMatterRevision):\(projection.generatedAt.timeIntervalSince1970)",
                kind: .projectionRefreshed,
                actor: .system,
                payload: [:],
                sourceType: nil,
                sourceEntityID: nil,
                at: self.clock(),
                in: ctx
            )
        }
    }

    // MARK: - Internals（static，接收 ctx，便于同事务复用）

    nonisolated private static func fetchMatter(id: UUID, in ctx: NSManagedObjectContext) throws -> HoloMatter? {
        let request = NSFetchRequest<HoloMatter>(entityName: "HoloMatter")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return try ctx.fetch(request).first
    }

    nonisolated private static func fetchOpenLoop(id: UUID, in ctx: NSManagedObjectContext) throws -> HoloMatterOpenLoop? {
        let request = NSFetchRequest<HoloMatterOpenLoop>(entityName: "HoloMatterOpenLoop")
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return try ctx.fetch(request).first
    }

    nonisolated private static func findMatterByOriginLink(
        contextPlanMessageID: UUID,
        in ctx: NSManagedObjectContext
    ) throws -> HoloMatter? {
        let request = NSFetchRequest<HoloMatterLink>(entityName: "HoloMatterLink")
        request.predicate = NSPredicate(
            format: "entityTypeRaw == %@ AND entityID == %@ AND deletedAt == nil AND statusRaw == %@ AND roleRaw == %@",
            HoloMatterLinkEntityType.contextPlan.rawValue,
            contextPlanMessageID.uuidString,
            HoloMatterLinkStatus.linked.rawValue,
            HoloMatterLinkRole.origin.rawValue
        )
        request.fetchLimit = 1
        guard let link = try ctx.fetch(request).first else { return nil }
        return try fetchMatter(id: link.matterID, in: ctx)
    }

    nonisolated private static func addLinkInternal(
        matter: HoloMatter,
        entityType: HoloMatterLinkEntityType,
        entityID: String,
        role: HoloMatterLinkRole,
        origin: HoloMatterLinkOrigin,
        confidence: Double,
        status: HoloMatterLinkStatus,
        sourceRevision: String?,
        at now: Date,
        in ctx: NSManagedObjectContext
    ) throws -> HoloMatterLink {
        // 幂等：同 matter + type + entity 的链接已存在（任意状态）→ 折叠复用，不建第二行。
        let request = NSFetchRequest<HoloMatterLink>(entityName: "HoloMatterLink")
        request.predicate = NSPredicate(
            format: "matterID == %@ AND entityTypeRaw == %@ AND entityID == %@ AND deletedAt == nil",
            matter.id as CVarArg,
            entityType.rawValue,
            entityID
        )
        request.fetchLimit = 1
        if let existing = try ctx.fetch(request).first {
            // 状态升级：proposed/rejected → linked 仅当请求明确要求 linked。
            if status == .linked && existing.status != .linked {
                existing.status = .linked
                existing.updatedAt = now
            }
            return existing
        }

        let link = HoloMatterLink(entity: NSEntityDescription.entity(forEntityName: "HoloMatterLink", in: ctx)!, insertInto: ctx)
        link.id = UUID()
        link.matterID = matter.id
        link.entityType = entityType
        link.entityID = entityID
        link.role = role
        link.origin = origin
        link.confidence = confidence
        link.status = status
        link.sourceRevision = sourceRevision
        link.createdAt = now
        link.updatedAt = now
        return link
    }

    nonisolated private static func addOpenLoopInternal(
        matter: HoloMatter,
        logicalKey: String,
        title: String,
        epistemic: HoloMatterOpenLoopEpistemic,
        state: HoloMatterOpenLoopState,
        priority: HoloMatterOpenLoopPriority,
        targetDate: Date?,
        sourceType: String?,
        sourceEntityID: String?,
        sourceRevision: Int64,
        at now: Date,
        in ctx: NSManagedObjectContext
    ) throws -> HoloMatterOpenLoop {
        // 幂等去重（方案 §10.2）：同 Matter 内同 logicalKey 已存在 → 不重复创建。
        let request = NSFetchRequest<HoloMatterOpenLoop>(entityName: "HoloMatterOpenLoop")
        request.predicate = NSPredicate(
            format: "matterID == %@ AND logicalKey == %@ AND deletedAt == nil",
            matter.id as CVarArg,
            logicalKey
        )
        request.fetchLimit = 1
        if let existing = try ctx.fetch(request).first {
            return existing
        }

        let loop = HoloMatterOpenLoop(entity: NSEntityDescription.entity(forEntityName: "HoloMatterOpenLoop", in: ctx)!, insertInto: ctx)
        loop.id = UUID()
        loop.matterID = matter.id
        loop.logicalKey = logicalKey
        loop.title = title
        loop.epistemic = epistemic
        loop.state = state
        loop.priority = priority
        loop.targetDate = targetDate
        loop.sourceTypeRaw = sourceType
        loop.sourceEntityID = sourceEntityID
        loop.sourceRevision = sourceRevision
        loop.revision = 1
        loop.createdAt = now
        loop.updatedAt = now
        return loop
    }

    nonisolated private static func appendEvent(
        matter: HoloMatter,
        idempotencyKey: String,
        kind: HoloMatterEventKind,
        actor: HoloMatterActor,
        payload: [String: String],
        sourceType: String?,
        sourceEntityID: String?,
        at now: Date,
        in ctx: NSManagedObjectContext,
        revertsEventID: UUID? = nil
    ) throws -> HoloMatterEvent {
        // 幂等（方案 §10.2）：重试不重复落事件。
        let request = NSFetchRequest<HoloMatterEvent>(entityName: "HoloMatterEvent")
        request.predicate = NSPredicate(
            format: "matterID == %@ AND idempotencyKey == %@ AND deletedAt == nil",
            matter.id as CVarArg,
            idempotencyKey
        )
        request.fetchLimit = 1
        if let existing = try ctx.fetch(request).first {
            return existing
        }

        let event = HoloMatterEvent(entity: NSEntityDescription.entity(forEntityName: "HoloMatterEvent", in: ctx)!, insertInto: ctx)
        event.id = UUID()
        event.matterID = matter.id
        event.idempotencyKey = idempotencyKey
        event.kind = kind
        event.actor = actor
        event.payload = payload
        event.sourceTypeRaw = sourceType
        event.sourceEntityID = sourceEntityID
        event.revertsEventID = revertsEventID
        event.createdAt = now
        return event
    }

    nonisolated private static func eventAlreadyReverted(eventID: UUID, in ctx: NSManagedObjectContext) throws -> Bool {
        let request = NSFetchRequest<HoloMatterEvent>(entityName: "HoloMatterEvent")
        request.predicate = NSPredicate(format: "revertsEventID == %@ AND deletedAt == nil", eventID as CVarArg)
        request.fetchLimit = 1
        return !(try ctx.fetch(request)).isEmpty
    }

    nonisolated private static func bumpRevision(of matter: HoloMatter, at now: Date) {
        matter.revision += 1
        matter.updatedAt = now
    }

    nonisolated private static func makeReceipt(for matter: HoloMatter, created: Bool, at now: Date) -> HoloMatterActivationReceipt {
        HoloMatterActivationReceipt(
            matterID: matter.id,
            created: created,
            linkedEntityIDs: [],
            suggestedOpenLoopIDs: [],
            eventID: matter.id  // 幂等回执：不产生新事件，用 matter.id 标识回执来源
        )
    }

    nonisolated private static func sanitizedTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return String(trimmed.prefix(60))
    }

    nonisolated static func normalizeLogicalKey(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let stripped = lowered.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return String(stripped.prefix(80))
    }

    nonisolated private static func lifecycleEventKey(matterID: UUID, to target: HoloMatterLifecycleStatus, revision: Int64) -> String {
        "lifecycle:\(matterID.uuidString):\(target.rawValue):\(revision)"
    }

    // MARK: - 事务包装

    /// 在注入的 context 上原子执行并保存；保存成功才算成功（方案 §10.1 第 8 步）。
    private func perform<T>(_ block: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        let ctx = context
        let result = try await ctx.perform {
            let value = try block(ctx)
            if ctx.hasChanges {
                try ctx.save()
            }
            return value
        }
        // async perform 返回后回到 MainActor，通知 UI 刷新。
        changeToken += 1
        return result
    }

    private func performAndWait<T>(_ block: (NSManagedObjectContext) throws -> T) -> T? {
        let ctx = context
        return try? ctx.performAndWait {
            let result = try block(ctx)
            if ctx.hasChanges {
                try ctx.save()
            }
            return result
        }
    }
}
