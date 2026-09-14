//
//  HoloMatterLinkedEntityChangeCoordinator.swift
//  Holo
//
//  关联实体（任务）变化 → Matter 投影联动（今日看板 Matter 化方案 §8.4）
//
//  职责：
//  1. 接收任务创建/改截止日/完成/撤回完成/归档/删除的类型化变更；
//  2. 按真实 taskID 查 MatterLink(.todoTask)，不扫描标题；
//  3. 让 Repository 记录幂等 linked-entity event、递增相关 Matter revision 并重建投影；
//  4. Task 仍是完成状态唯一真相源，Matter 不复制任务完成布尔值；
//  5. 同一 taskID + changedAt + changeKind 只处理一次；
//  6. 无关联 Matter 的任务立即返回，不给普通任务路径增加成本。
//

import Foundation
import CoreData
import Combine
import os.log

// MARK: - 类型化任务变更

nonisolated enum HoloTaskChangeKind: String, Equatable, Sendable {
    case created
    case dueDateChanged
    case completed
    case completionReverted
    case archived
    case deleted
}

nonisolated struct HoloTaskChange: Equatable, Sendable {
    let taskID: UUID
    let changeKind: HoloTaskChangeKind
    /// 变更时刻（取 task.updatedAt；幂等键组成部分）。
    let changedAt: Date

    nonisolated static let notificationKey = "change"
}

extension Notification.Name {
    /// 类型化任务变更（object 携带 HoloTaskChange 值；禁止 object=nil 反猜实体）。
    static let holoTaskChange = Notification.Name("com.holo.taskTypedChange")
}

// MARK: - 协调器

@MainActor
final class HoloMatterLinkedEntityChangeCoordinator {

    static let shared = HoloMatterLinkedEntityChangeCoordinator(repository: .shared)

    private let repository: HoloMatterRepository
    private let logger = Logger(subsystem: "com.holo.app", category: "MatterLinkedEntity")

    /// 已处理的变更键（进程内去重：taskID+changedAt+changeKind；量级很小，不做淘汰）。
    private var handledKeys: Set<String> = []

    private var changeObserver: NSObjectProtocol?

    init(repository: HoloMatterRepository) {
        self.repository = repository
    }

    /// 启动监听（App 启动后调用一次）。只在 Matter 存储开启时订阅。
    func startObserving() {
        guard HoloMatterRolloutPolicy.storageEnabled, changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .holoTaskChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let change = note.object as? HoloTaskChange else { return }
            Task { @MainActor in
                try? await self?.handleTaskChange(change)
            }
        }
    }

    /// 处理一条类型化任务变更：有关联 Matter 时 bump revision 并重建投影。
    /// 无关联任务零成本返回；同一变更幂等。
    func handleTaskChange(_ change: HoloTaskChange) async throws {
        let key = "\(change.taskID.uuidString)|\(change.changedAt.timeIntervalSince1970)|\(change.changeKind.rawValue)"
        guard !handledKeys.contains(key) else { return }
        handledKeys.insert(key)

        // 按真实 taskID 找链接（不扫标题）。无关链接 → 直接返回。
        let link = findTaskLink(taskID: change.taskID)
        guard let link else { return }
        guard let matter = repository.matter(id: link.matterID) else { return }

        let now = Date()
        Self.bumpRevision(of: matter, at: now)
        _ = appendLinkedEntityEvent(matter: matter, change: change, at: now)
        if repository.context.hasChanges {
            try repository.context.save()
        }
        try await refreshProjection(matterID: matter.id)

        logger.info("linked task 变更已联动 Matter：\(change.changeKind.rawValue, privacy: .public)")
    }

    // MARK: - Internals

    private func findTaskLink(taskID: UUID) -> HoloMatterLink? {
        let request = NSFetchRequest<HoloMatterLink>(entityName: "HoloMatterLink")
        request.predicate = NSPredicate(
            format: "entityTypeRaw == %@ AND entityID == %@ AND deletedAt == nil AND statusRaw == %@",
            HoloMatterLinkEntityType.todoTask.rawValue,
            taskID.uuidString,
            HoloMatterLinkStatus.linked.rawValue
        )
        request.fetchLimit = 1
        return (try? repository.context.fetch(request))?.first
    }

    /// 关联实体事件（幂等键含 taskID+changedAt+changeKind；重复投递折叠）。
    private func appendLinkedEntityEvent(matter: HoloMatter, change: HoloTaskChange, at now: Date) -> HoloMatterEvent? {
        let request = NSFetchRequest<HoloMatterEvent>(entityName: "HoloMatterEvent")
        request.predicate = NSPredicate(
            format: "matterID == %@ AND idempotencyKey == %@ AND deletedAt == nil",
            matter.id as CVarArg,
            Self.linkedEventKey(matterID: matter.id, change: change)
        )
        request.fetchLimit = 1
        if let existing = try? repository.context.fetch(request).first {
            return existing
        }
        let event = HoloMatterEvent(
            entity: NSEntityDescription.entity(forEntityName: "HoloMatterEvent", in: repository.context)!,
            insertInto: repository.context
        )
        event.id = UUID()
        event.matterID = matter.id
        event.idempotencyKey = Self.linkedEventKey(matterID: matter.id, change: change)
        event.kind = .linkAdded
        event.actor = .system
        event.payload = ["taskID": change.taskID.uuidString, "changeKind": change.changeKind.rawValue]
        event.sourceTypeRaw = HoloMatterLinkEntityType.todoTask.rawValue
        event.sourceEntityID = change.taskID.uuidString
        event.createdAt = now
        return event
    }

    nonisolated private static func linkedEventKey(matterID: UUID, change: HoloTaskChange) -> String {
        "linkedTask:\(matterID.uuidString):\(change.taskID.uuidString):\(change.changeKind.rawValue):\(change.changedAt.timeIntervalSince1970)"
    }

    nonisolated private static func bumpRevision(of matter: HoloMatter, at now: Date) {
        matter.revision += 1
        matter.updatedAt = now
    }

    /// 用确定性 builder 重建投影（AI 润色由对账链路在后续覆盖）。
    private func refreshProjection(matterID: UUID) async throws {
        guard let matter = repository.matter(id: matterID) else { return }
        let loops = repository.openLoops(matterID: matterID).map {
            HoloMatterAttentionPolicy.LoopInput(
                title: $0.title, state: $0.state, epistemic: $0.epistemic, targetDate: $0.targetDate
            )
        }
        let snapshot = HoloMatterProjectionBuilder.MatterSnapshot(
            matterID: matter.id,
            title: matter.title,
            revision: matter.revision,
            targetDate: matter.targetDate,
            phase: matter.phase
        )
        try await repository.saveProjection(
            matterID: matterID,
            projection: HoloMatterProjectionBuilder.buildDeterministic(from: snapshot, loops: loops)
        )
    }
}