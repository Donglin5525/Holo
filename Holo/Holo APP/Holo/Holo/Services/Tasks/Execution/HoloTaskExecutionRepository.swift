//
//  HoloTaskExecutionRepository.swift
//  Holo
//
//  分步推进持久化读取与视图组装（2026-09-25 实施规格 §7.5/§9.1）
//  所有读取以真实 taskID 校验归属；同 operationID 的同步副本在查询层去重。
//

import Foundation
import CoreData

@MainActor
final class HoloTaskExecutionRepository {

    let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    // MARK: - 版本读取

    /// 当前有效版本：以 task.activeExecutionRevisionID 为入口，验证版本存在且未删除。
    /// 指针失效（云端迟到/缺记录）返回 nil，由调用方呈现 syncing/needsReview，不猜新版本。
    func activeRevision(taskID: UUID) -> HoloTaskExecutionRevision? {
        let request = HoloTaskExecutionRevision.fetchRequest()
        request.predicate = NSPredicate(
            format: "taskID == %@ AND deletedAt == nil",
            taskID as CVarArg
        )
        request.fetchLimit = 1
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        let revisions = deduplicatedRevisions((try? context.fetch(request)) ?? [])
        guard let task = findTask(taskID) else { return nil }
        if let pointer = task.activeExecutionRevisionID,
           let pointed = revisions.first(where: { $0.id == pointer }) {
            return pointed
        }
        return revisions.first
    }

    func revision(id: UUID) -> HoloTaskExecutionRevision? {
        let request = HoloTaskExecutionRevision.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return deduplicatedRevisions((try? context.fetch(request)) ?? []).first
    }

    /// 同 operationID 版本（采纳幂等；同步副本去重后判定）
    func revision(operationID: String) -> HoloTaskExecutionRevision? {
        guard !operationID.isEmpty else { return nil }
        let request = HoloTaskExecutionRevision.fetchRequest()
        request.predicate = NSPredicate(format: "operationID == %@ AND deletedAt == nil", operationID)
        request.fetchLimit = 2
        return deduplicatedRevisions((try? context.fetch(request)) ?? []).first
    }

    /// 未被后继版本收敛的 head（并发分叉检测，规格 §9.1）
    func unresolvedHeads(taskID: UUID) -> [HoloTaskExecutionRevision] {
        let request = HoloTaskExecutionRevision.fetchRequest()
        request.predicate = NSPredicate(format: "taskID == %@ AND deletedAt == nil", taskID as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let all = deduplicatedRevisions((try? context.fetch(request)) ?? [])
        guard all.count > 1 else { return Array(all.suffix(1)) }
        var superseded = Set<UUID>()
        for revision in all {
            for parent in revision.parentRevisionIDs {
                superseded.insert(parent)
            }
        }
        let heads = all.filter { !superseded.contains($0.id) }
        return heads
    }

    // MARK: - 步骤读取

    /// 任务全部未删除步骤（含历史版本节点；活动范围由拓扑决定）
    func steps(taskID: UUID) -> [HoloTaskExecutionStep] {
        let request = HoloTaskExecutionStep.fetchRequest()
        request.predicate = NSPredicate(format: "taskID == %@ AND deletedAt == nil", taskID as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return deduplicatedSteps((try? context.fetch(request)) ?? [])
    }

    func step(id: UUID, taskID: UUID) -> HoloTaskExecutionStep? {
        let request = HoloTaskExecutionStep.fetchRequest()
        request.predicate = NSPredicate(
            format: "id == %@ AND taskID == %@ AND deletedAt == nil",
            id as CVarArg, taskID as CVarArg
        )
        request.fetchLimit = 2
        return deduplicatedSteps((try? context.fetch(request)) ?? []).first
    }

    // MARK: - 回执读取

    func receipt(operationID: String) -> HoloTaskExecutionReceipt? {
        guard !operationID.isEmpty else { return nil }
        let request = HoloTaskExecutionReceipt.fetchRequest()
        request.predicate = NSPredicate(format: "operationID == %@ AND deletedAt == nil", operationID)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    // MARK: - 清单读取

    func checklist(task: TodoTask) -> [CheckItem] {
        (task.checkItems?.allObjects as? [CheckItem] ?? [])
            .sorted { $0.order < $1.order }
    }

    func checklistByID(taskID: UUID) -> [UUID: Bool] {
        guard let task = findTask(taskID) else { return [:] }
        var map: [UUID: Bool] = [:]
        for item in checklist(task: task) {
            map[item.id] = item.isChecked
        }
        return map
    }

    // MARK: - 视图组装（UI 唯一读取口径）

    /// 组装执行视图：状态派生、下一步选择、契约有效性一次完成。
    /// revision 为 nil 表示 absent（未采纳）。
    func executionView(taskID: UUID, cursorStepID: UUID?) -> HoloTaskExecutionView? {
        guard let task = findTask(taskID) else { return nil }
        guard let revision = activeRevision(taskID: taskID) else {
            return HoloTaskExecutionView(
                taskID: taskID,
                taskCompleted: task.completed,
                revision: nil,
                topology: nil,
                contract: nil,
                contractValid: false,
                state: task.completed ? .rootCompleted : (taskUnavailable(task) ? .unavailable : .absent),
                steps: [],
                resolution: nil,
                checklist: checklist(task: task)
            )
        }

        let topology = revision.topology ?? HoloTaskExecutionTopology(nodes: [])
        let allSteps = steps(taskID: taskID)
        var stepsByID: [UUID: HoloTaskExecutionStep] = [:]
        for step in allSteps { stepsByID[step.id] = step }

        let snapshots = allSteps.reduce(into: [UUID: HoloTaskExecutionPolicy.StepSnapshot]()) { acc, step in
            acc[step.id] = HoloTaskExecutionPolicy.StepSnapshot(
                id: step.id,
                stateRaw: step.stateRaw,
                stateVersion: step.stateVersion
            )
        }

        let resolution = HoloTaskExecutionPolicy.resolve(
            topology: topology,
            stepsByID: snapshots,
            checklistByID: checklistByID(taskID: taskID),
            cursorStepID: cursorStepID
        )

        // 契约有效性：契约依据指纹与当前任务事实一致，且无未解决分叉
        let contract = revision.outcomeContract
        var contractValid = true
        if let contract {
            let currentBasis = HoloTaskExecutionFingerprint.contractBasis(
                taskID: taskID,
                title: task.title,
                desc: task.desc,
                checklist: checklistFacts(task: task, contract: contract)
            )
            contractValid = (currentBasis == contract.contractBasisFingerprint)
        } else {
            contractValid = false
        }
        if unresolvedHeads(taskID: taskID).count > 1 {
            contractValid = false
        }

        let state = HoloTaskExecutionPolicy.derivedState(
            resolution: resolution,
            topology: topology,
            taskCompleted: task.completed,
            contractValid: contractValid
        )

        // 活动节点对应的步骤实体，按稳定顺序
        let activeSteps: [HoloTaskExecutionStep] = topology.nodes.compactMap { stepsByID[$0.id] }

        return HoloTaskExecutionView(
            taskID: taskID,
            taskCompleted: task.completed,
            revision: revision,
            topology: topology,
            contract: contract,
            contractValid: contractValid,
            state: state,
            steps: activeSteps,
            resolution: resolution,
            checklist: checklist(task: task)
        )
    }

    /// 契约指纹用的清单事实（是否必要 = 契约里声明了对应 checklist 要求）
    func checklistFacts(task: TodoTask, contract: HoloTaskExecutionOutcomeContract?) -> [HoloTaskExecutionChecklistItem] {
        let requiredItemIDs = Set(
            (contract?.requirements ?? []).compactMap { req -> UUID? in
                guard req.source == .checklist else { return nil }
                return req.sourceID.flatMap(UUID.init(uuidString:))
            }
        )
        return checklist(task: task).map { item in
            HoloTaskExecutionChecklistItem(
                id: item.id,
                title: item.title,
                isChecked: item.isChecked,
                isRequired: requiredItemIDs.contains(item.id)
            )
        }
    }

    /// 候选快照指纹的当前值（提案协调器与采纳校验共用）
    func currentSnapshotFingerprint(taskID: UUID) -> String? {
        guard let task = findTask(taskID) else { return nil }
        let revision = activeRevision(taskID: taskID)
        let allSteps = steps(taskID: taskID)
        let versions = allSteps.reduce(into: [UUID: Int64]()) { $0[$1.id] = $1.stateVersion }
        let contract = revision?.outcomeContract
        return HoloTaskExecutionFingerprint.snapshot(
            taskID: taskID,
            title: task.title,
            desc: task.desc,
            dueDate: task.dueDate,
            checklist: checklistFacts(task: task, contract: contract),
            activeRevisionID: revision?.id,
            targetStepStateVersions: versions
        )
    }

    // MARK: - 归属清理（规格 §9.3：原任务永久删除时按真实归属清理，不能只删 UI）

    /// 永久删除任务时清理其全部执行数据（版本/步骤/回执）
    func purgeExecutionData(taskID: UUID) {
        let predicate = NSPredicate(format: "taskID == %@", taskID as CVarArg)
        let revisionRequest = NSFetchRequest<NSManagedObject>(entityName: "HoloTaskExecutionRevision")
        revisionRequest.predicate = predicate
        let stepRequest = NSFetchRequest<NSManagedObject>(entityName: "HoloTaskExecutionStep")
        stepRequest.predicate = predicate
        let receiptRequest = NSFetchRequest<NSManagedObject>(entityName: "HoloTaskExecutionReceipt")
        receiptRequest.predicate = predicate
        for request in [revisionRequest, stepRequest, receiptRequest] {
            for object in (try? context.fetch(request)) ?? [] {
                context.delete(object)
            }
        }
    }

    // MARK: - 内部

    func findTask(_ id: UUID) -> TodoTask? {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    func taskUnavailable(_ task: TodoTask) -> Bool {
        task.archived || task.repeatRule != nil
    }

    /// 同 operationID 的同步副本去重（逻辑去重，不依赖本机内存 Set；规格 §9.1）
    func deduplicatedRevisions(_ revisions: [HoloTaskExecutionRevision]) -> [HoloTaskExecutionRevision] {
        var seen = Set<String>()
        var byID: [UUID: HoloTaskExecutionRevision] = [:]
        for revision in revisions {
            let key = revision.operationID.isEmpty ? revision.id.uuidString : revision.operationID
            if seen.contains(key) { continue }
            seen.insert(key)
            byID[revision.id] = revision
        }
        return byID.values.sorted { $0.createdAt < $1.createdAt }
    }

    func deduplicatedSteps(_ steps: [HoloTaskExecutionStep]) -> [HoloTaskExecutionStep] {
        var byID: [UUID: HoloTaskExecutionStep] = [:]
        for step in steps { byID[step.id] = step }
        return byID.values.sorted { $0.createdAt < $1.createdAt }
    }
}

// MARK: - 执行视图（UI 消费结构）

struct HoloTaskExecutionView {
    let taskID: UUID
    let taskCompleted: Bool
    /// nil = 未采纳（absent / unavailable）
    let revision: HoloTaskExecutionRevision?
    let topology: HoloTaskExecutionTopology?
    let contract: HoloTaskExecutionOutcomeContract?
    let contractValid: Bool
    let state: HoloTaskExecutionDerivedState
    /// 活动拓扑顺序的步骤实体
    let steps: [HoloTaskExecutionStep]
    let resolution: HoloTaskExecutionPolicy.Resolution?
    let checklist: [CheckItem]

    /// 当前应展示的动作（游标优先）
    var currentStepID: UUID? {
        resolution?.actionableIDs.first
    }

    func step(_ id: UUID) -> HoloTaskExecutionStep? {
        steps.first { $0.id == id }
    }

    /// 当前动作是否为最后一个必要待办（合并按钮判定：一步同时核验结果）
    func isFinalRequiredStep(_ stepID: UUID) -> Bool {
        guard let topology, let resolution else { return false }
        let pendingRequired = topology.nodes.filter { node in
            guard node.required, node.kind != .group else { return false }
            switch resolution.states[node.id] {
            case .done, .group(true): return false
            default: return true
            }
        }
        return pendingRequired.count == 1 && pendingRequired[0].id == stepID
    }

    /// 等待中的步骤（等待原因展示用）
    var waitingSteps: [HoloTaskExecutionStep] {
        guard let resolution else { return [] }
        return steps.filter { step in
            guard case .waiting = resolution.states[step.id] else { return false }
            return true
        }
    }

    /// 未完成的必要节点数
    var pendingRequiredCount: Int {
        guard let topology, let resolution else { return 0 }
        return topology.nodes.filter { node in
            guard node.required, node.kind != .group else { return false }
            switch resolution.states[node.id] {
            case .done, .group(true): return false
            default: return true
            }
        }.count
    }
}
