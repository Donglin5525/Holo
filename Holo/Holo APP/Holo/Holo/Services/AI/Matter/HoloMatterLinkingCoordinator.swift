//
//  HoloMatterLinkingCoordinator.swift
//  Holo
//
//  任务与 Matter 的补链协调（今日看板 Matter 化方案 §8.3）
//
//  两条补链顺序都必须闭环：
//  1. Matter 已激活、任务后创建 → 创建回执即时链（linkCreatedTasks）
//  2. 任务先创建、Matter 后激活 → 激活时按同一 contextPlanMessageID 的 V2 回执补链
//     （linkExistingTasksFromReceipts）
//
//  红线：
//  - link 只有真实 taskID，不用标题建立关系；legacy 回执（无 taskID）不伪造链接
//  - link 写入幂等（Repository 层折叠），重复调用返回已有 link
//  - Task 成功但 link 失败不删 Task：上层显示「已加入待办，正在补充关联」并允许重试
//

import Foundation
import CoreData
import os.log

@MainActor
final class HoloMatterLinkingCoordinator {

    static let shared = HoloMatterLinkingCoordinator(repository: .shared)

    private let repository: HoloMatterRepository
    private let logger = Logger(subsystem: "com.holo.app", category: "MatterLinking")

    init(repository: HoloMatterRepository) {
        self.repository = repository
    }

    // MARK: 创建后即时链

    /// 任务创建成功后调用：该方案卡已激活 Matter 时，把新任务以 action 角色链入。
    /// 单个失败不抛错（不回滚任务）；返回真实建立链接的任务 ID。
    @discardableResult
    static func linkCreatedTasks(
        contextPlanMessageID: UUID,
        taskIDs: [UUID],
        repository: HoloMatterRepository = .shared
    ) async -> [UUID] {
        await HoloMatterLinkingCoordinator(repository: repository).linkCreatedTasksInternal(
            contextPlanMessageID: contextPlanMessageID,
            taskIDs: taskIDs
        )
    }

    private func linkCreatedTasksInternal(
        contextPlanMessageID: UUID,
        taskIDs: [UUID]
    ) async -> [UUID] {
        guard let matter = repository.findMatterActivated(from: contextPlanMessageID) else {
            return []
        }
        var linked: [UUID] = []
        for taskID in taskIDs {
            do {
                _ = try await repository.addLink(
                    matterID: matter.id,
                    entityType: .todoTask,
                    entityID: taskID.uuidString,
                    role: .action,
                    origin: .system
                )
                linked.append(taskID)
            } catch {
                // link 失败不删 Task；激活补链通道可按 V2 回执兜底。
                logger.warning("即时补链失败（可由激活补链兜底）：\(error)")
            }
        }
        return linked
    }

    // MARK: 激活后补链

    /// Matter 激活完成时调用：按同一 contextPlanMessageID 的 V2 回执，把已存在的任务链入。
    /// legacy 回执（taskID=nil）跳过——不伪造链接；查询器可注入供单测。
    /// - Returns: 真实补链成功的任务 ID。
    @discardableResult
    static func linkExistingTasksFromReceipts(
        matterID: UUID,
        contextPlanMessageID: UUID,
        taskFinder: @MainActor (UUID) -> TodoTask?,
        aiSourceFinder: @MainActor (String, String) -> TodoTask?,
        receipts: [String: HoloContextPlanTaskReceiptV2],
        repository: HoloMatterRepository = .shared
    ) async throws -> [UUID] {
        try await HoloMatterLinkingCoordinator(repository: repository).linkExistingTasksInternal(
            matterID: matterID,
            contextPlanMessageID: contextPlanMessageID,
            taskFinder: taskFinder,
            aiSourceFinder: aiSourceFinder,
            receipts: receipts
        )
    }

    private func linkExistingTasksInternal(
        matterID: UUID,
        contextPlanMessageID: UUID,
        taskFinder: @MainActor (UUID) -> TodoTask?,
        aiSourceFinder: @MainActor (String, String) -> TodoTask?,
        receipts: [String: HoloContextPlanTaskReceiptV2]
    ) async throws -> [UUID] {
        // 只补本方案卡来源的回执（同 contextPlanMessageID 的 V2 记录）。
        // legacy 回执 sourceMessageID=nil 无法归属 → 不补链（不伪造）。
        let relevant = receipts.values.filter { $0.sourceMessageID == contextPlanMessageID }
        var linked: [UUID] = []
        for receipt in relevant {
            guard let taskID = receipt.taskID else { continue } // legacy：无真实 ID 不补链
            // 双重校验：回执里的任务必须真实存在（被删任务不复活、不链入）。
            let exists = taskFinder(taskID) != nil
                || aiSourceFinder(
                    receipt.sourceMessageID?.uuidString ?? "",
                    receipt.sourceItemID
                ) != nil
            guard exists else { continue }
            _ = try await repository.addLink(
                matterID: matterID,
                entityType: .todoTask,
                entityID: taskID.uuidString,
                role: .action,
                origin: .system
            )
            linked.append(taskID)
        }
        if !linked.isEmpty {
            logger.info("激活补链完成：\(linked.count) 条任务链入 \(matterID.uuidString, privacy: .public)")
        }
        return linked
    }

    // MARK: 从 Open Loop 建任务（§8.4：openLoopAction → 可执行）

    /// 把已确认 Open Loop 转成真实任务并建立双向可追溯关系：
    /// 任务链入 Matter（link 行 sourceRevision 记 loopID），重复调用幂等返回既有任务。
    @discardableResult
    static func createTaskFromOpenLoop(
        matterID: UUID,
        openLoopID: UUID,
        repository: HoloMatterRepository = .shared
    ) async throws -> TodoTask {
        try await HoloMatterLinkingCoordinator(repository: repository)
            .createTaskFromOpenLoopInternal(matterID: matterID, openLoopID: openLoopID)
    }

    private func createTaskFromOpenLoopInternal(
        matterID: UUID,
        openLoopID: UUID
    ) async throws -> TodoTask {
        let repo = TodoRepository.shared
        let context = repository.context

        // 幂等：该 loop 已有链接任务 → 直接返回，不重复建。
        let request = NSFetchRequest<HoloMatterLink>(entityName: "HoloMatterLink")
        request.predicate = NSPredicate(
            format: "matterID == %@ AND entityTypeRaw == %@ AND sourceRevision == %@ AND deletedAt == nil AND statusRaw == %@",
            matterID as CVarArg,
            HoloMatterLinkEntityType.todoTask.rawValue,
            openLoopID.uuidString,
            HoloMatterLinkStatus.linked.rawValue
        )
        request.fetchLimit = 1
        if let existing = try context.fetch(request).first,
           let taskID = UUID(uuidString: existing.entityID),
           let task = repo.findTask(by: taskID) {
            return task
        }

        guard let loop = repository.openLoops(matterID: matterID).first(where: { $0.id == openLoopID }) else {
            throw HoloMatterRepositoryError.notFound("HoloMatterOpenLoop \(openLoopID)")
        }
        guard let matter = repository.matter(id: matterID) else {
            throw HoloMatterRepositoryError.notFound("HoloMatter \(matterID)")
        }

        // 创建任务（loop 标题只是本次展示取值，关联全部走真实 ID）。
        let task = try repo.createTask(title: loop.title)
        _ = try await repository.addLink(
            matterID: matterID,
            entityType: .todoTask,
            entityID: task.id.uuidString,
            role: .action,
            origin: .system,
            sourceRevision: openLoopID.uuidString
        )
        logger.info("Open Loop 已建任务并链入 Matter \(matter.id.uuidString, privacy: .public)")
        return task
    }
}
