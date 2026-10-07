//
//  HoloTaskExecutionService.swift
//  Holo
//
//  分步推进唯一命令边界（2026-09-25 实施规格 §7.4）
//
//  一次业务命令在同一个 Core Data context 事务中验证、修改、写回执并 save 一次；
//  失败全部 rollback，界面不出现一半成功。
//  完成不变量：步骤完成/等待/撤回零 AI 调用；根完成只由用户结果断言或直接完成触发；
//  根完成不写步骤状态（准备≠结果、不伪造执行进度）。
//

import Foundation
import CoreData
import Combine
import os.log

@MainActor
final class HoloTaskExecutionService: ObservableObject {

    static let shared = HoloTaskExecutionService()

    private let logger = Logger(subsystem: "com.holo.app", category: "HoloTaskExecutionService")

    /// 完成策略入口开关（规格 §9.4：入口/AI/执行读取三开关分离，见 RolloutPolicy）
    var isEntryEnabled: Bool { HoloTaskExecutionRolloutPolicy.entryEnabled }

    private var repositoryOverride: HoloTaskExecutionRepository?

    /// 生产：共享 TodoRepository 的主上下文；测试：注入独立上下文
    func repository(in repo: TodoRepository) -> HoloTaskExecutionRepository {
        repositoryOverride ?? HoloTaskExecutionRepository(context: repo.context)
    }

    /// 测试注入
    static func makeTestService(context: NSManagedObjectContext) -> HoloTaskExecutionService {
        let service = HoloTaskExecutionService()
        service.repositoryOverride = HoloTaskExecutionRepository(context: context)
        return service
    }

    // MARK: - 采纳（原子保存契约 + 计划，规格 §4.2 第 4 步）

    struct AdoptionInput {
        var taskID: UUID
        var expectedFingerprint: String
        var outcomeSummary: String
        var verificationPrompt: String
        var requirements: [HoloTaskExecutionRequirement]
        var steps: [HoloTaskExecutionManualStep]
        var originMatterID: UUID?
        var acceptedSource: HoloTaskExecutionPlanSource
        var operationID: String
        var sourceSurface: String
    }

    /// 采纳一个方案（AI 候选或手工计划统一走这里）。
    /// - Returns: 新建的版本
    @discardableResult
    func adopt(_ input: AdoptionInput, in repo: TodoRepository) throws -> HoloTaskExecutionRevision {
        let repository = repository(in: repo)
        let context = repo.context

        // 幂等：同 operationID 已采纳 → 返回既有版本，不产生第二份
        if let existing = repository.revision(operationID: input.operationID) {
            return existing
        }

        guard let task = repository.findTask(input.taskID) else { throw HoloTaskExecutionError.taskNotFound }
        try guardAdoptable(task)
        guard task.executionSchemaVersion < 1 else { throw HoloTaskExecutionError.alreadyManaged }

        // 源指纹重验：候选建立后任务改了/完成了 → 失效
        if let current = repository.currentSnapshotFingerprint(taskID: input.taskID),
           current != input.expectedFingerprint {
            throw HoloTaskExecutionError.sourceStale
        }

        let now = Date()

        // 契约：AI/手工要求 + 未完成清单义务自动补齐（规格 §3.4：每个未完成清单项必须被交代）
        let checklist = repository.checklist(task: task)
        var requirements = input.requirements
        var usedRequirementIDs = Set(requirements.map(\.id))
        var checklistRequirements: [HoloTaskExecutionRequirement] = []
        for item in checklist where !item.isChecked {
            let sourceID = item.id.uuidString
            let alreadyCovered = requirements.contains { $0.source == .checklist && $0.sourceID == sourceID }
            guard !alreadyCovered else { continue }
            let id = Self.nextRequirementID(used: &usedRequirementIDs)
            checklistRequirements.append(HoloTaskExecutionRequirement(
                id: id,
                content: item.title,
                source: .checklist,
                sourceID: sourceID
            ))
        }
        requirements.append(contentsOf: checklistRequirements)

        let topologyNodes = try Self.buildAdoptionTopology(
            steps: input.steps,
            checklist: checklist,
            requirementIDForChecklistItem: { itemID in
                requirements.first { $0.source == .checklist && $0.sourceID == itemID.uuidString }?.id
            }
        )
        let topology = HoloTaskExecutionTopology(nodes: topologyNodes)

        // 覆盖是采纳的必要条件（规格 §5.4）；手工构建器天然覆盖，AI 缺口在协调器预览前拦截
        let gaps = HoloTaskExecutionPolicy.coverageGaps(requirements: requirements, topology: topology)
        guard gaps.isEmpty else {
            throw HoloTaskExecutionError.invalidProposal(reason: "结果要求未被任何步骤覆盖: \(gaps.joined(separator: ","))")
        }

        let contract = HoloTaskExecutionOutcomeContract(
            outcomeSummary: input.outcomeSummary,
            verificationPrompt: input.verificationPrompt,
            requirements: requirements,
            contractBasisFingerprint: HoloTaskExecutionFingerprint.contractBasis(
                taskID: input.taskID,
                title: task.title,
                desc: task.desc,
                checklist: repository.checklistFacts(task: task, contract: nil)
            ),
            scopeChanges: []
        )

        let revision = HoloTaskExecutionRevision(entity: NSEntityDescription.entity(forEntityName: "HoloTaskExecutionRevision", in: context)!, insertInto: context)
        revision.id = UUID()
        revision.taskID = input.taskID
        revision.originMatterID = input.originMatterID
        revision.parentRevisionIDs = []
        revision.operationID = input.operationID
        revision.schemaVersion = 1
        revision.sourceFingerprint = input.expectedFingerprint
        revision.outcomeContract = contract
        revision.topology = topology
        revision.acceptedSource = input.acceptedSource
        revision.createdAt = now

        for node in topologyNodes where node.kind != .group {
            let step = HoloTaskExecutionStep(entity: NSEntityDescription.entity(forEntityName: "HoloTaskExecutionStep", in: context)!, insertInto: context)
            step.id = node.id
            step.taskID = input.taskID
            step.originRevisionID = revision.id
            step.kindRaw = node.kindRaw
            let source = input.steps.first { $0.id == node.id }
            step.actionText = source?.action
            step.doneWhen = source?.doneWhen
            step.sourceCheckItemID = node.sourceCheckItemID
            step.stateRaw = HoloTaskExecutionStepState.pending.rawValue
            step.stateVersion = 1
            step.createdAt = now
            step.updatedAt = now
        }

        task.executionSchemaVersion = 1
        task.activeExecutionRevisionID = revision.id
        task.updatedAt = now

        Self.appendReceipt(
            in: context,
            operationID: input.operationID,
            taskID: input.taskID,
            revisionID: revision.id,
            stepID: nil,
            command: "adopt",
            actor: .user,
            sourceSurface: input.sourceSurface,
            expectedStateVersion: nil,
            before: nil,
            after: ["revisionID": revision.id.uuidString, "nodeCount": "\(topologyNodes.count)"]
        )

        do {
            try context.save()
        } catch {
            context.rollback()
            logger.error("采纳保存失败: \(error.localizedDescription, privacy: .public)")
            throw HoloTaskExecutionError.atomicSaveFailed(error.localizedDescription)
        }

        Self.afterCommit(repo: repo, taskChange: nil)
        return revision
    }

    // MARK: - 步骤命令

    /// 完成一步（本地即时保存；规格 §8.2 普通步骤不走全局 pending 槽）
    func completeStep(
        stepID: UUID,
        revisionID: UUID,
        expectedStateVersion: Int64,
        operationID: String,
        sourceSurface: String,
        in repo: TodoRepository
    ) throws {
        if repository(in: repo).receipt(operationID: operationID) != nil { return } // 幂等
        try mutateStep(
            stepID: stepID,
            revisionID: revisionID,
            expectedStateVersion: expectedStateVersion,
            requireDone: false,
            command: "completeStep",
            sourceSurface: sourceSurface,
            operationID: operationID,
            in: repo
        ) { step in
            step.stateRaw = HoloTaskExecutionStepState.done.rawValue
            step.completedAt = Date()
        }
    }

    /// 撤回普通步骤完成：只恢复该步骤原状态，不删除后续真实完成记录（规格 §8.3）
    /// 根已完成时用户重开必要步骤：同一事务重开根任务并记录 reopenRoot 回执（旧断言由回执链失效）。
    func reopenStep(
        stepID: UUID,
        revisionID: UUID,
        expectedStateVersion: Int64,
        operationID: String,
        sourceSurface: String,
        in repo: TodoRepository
    ) throws {
        if repository(in: repo).receipt(operationID: operationID) != nil { return }
        let repository = repository(in: repo)
        guard let revision = repository.revision(id: revisionID) else {
            throw HoloTaskExecutionError.revisionNotFound
        }
        let planTaskID = revision.taskID
        try mutateStep(
            stepID: stepID,
            revisionID: revisionID,
            expectedStateVersion: expectedStateVersion,
            requireDone: true,
            command: "reopenStep",
            sourceSurface: sourceSurface,
            operationID: operationID,
            in: repo
        ) { step in
            step.stateRaw = HoloTaskExecutionStepState.pending.rawValue
            step.completedAt = nil
            // 规格 §8.3：不能出现根仍完成、用户却在补做必要步骤的无提示矛盾
            if let task = repository.findTask(planTaskID), task.completed {
                task.completed = false
                task.completedAt = nil
                task.updatedAt = Date()
                Self.appendReceipt(
                    in: step.managedObjectContext ?? repo.context,
                    operationID: "\(operationID)-root",
                    taskID: planTaskID,
                    revisionID: revisionID,
                    stepID: stepID,
                    command: "reopenRoot",
                    actor: .user,
                    sourceSurface: sourceSurface,
                    expectedStateVersion: nil,
                    before: ["completed": "1"],
                    after: ["completed": "0"]
                )
            }
        }
        // 上游撤回后，已完成下游保留真实历史；契约不受影响（勾一步不触发复核，规格 §7.5）
        _ = repository
    }

    /// 等待：记录用户明确提供的原因；不把等待记为完成（规格 §4.5）
    func setWaiting(
        stepID: UUID,
        revisionID: UUID,
        expectedStateVersion: Int64,
        reason: String?,
        reviewAfter: Date?,
        operationID: String,
        sourceSurface: String,
        in repo: TodoRepository
    ) throws {
        if repository(in: repo).receipt(operationID: operationID) != nil { return }
        try mutateStep(
            stepID: stepID,
            revisionID: revisionID,
            expectedStateVersion: expectedStateVersion,
            requireDone: false,
            command: "setWaiting",
            sourceSurface: sourceSurface,
            operationID: operationID,
            in: repo
        ) { step in
            step.stateRaw = HoloTaskExecutionStepState.waiting.rawValue
            step.waitReason = reason
            step.reviewAfter = reviewAfter
        }
    }

    /// 从等待恢复（到提醒时间只是「可以检查」，恢复由用户触发，规格 §4.5）
    func resumeStep(
        stepID: UUID,
        revisionID: UUID,
        expectedStateVersion: Int64,
        operationID: String,
        sourceSurface: String,
        in repo: TodoRepository
    ) throws {
        if repository(in: repo).receipt(operationID: operationID) != nil { return }
        try mutateStep(
            stepID: stepID,
            revisionID: revisionID,
            expectedStateVersion: expectedStateVersion,
            requireDone: false,
            command: "resumeStep",
            sourceSurface: sourceSurface,
            operationID: operationID,
            in: repo
        ) { step in
            step.stateRaw = HoloTaskExecutionStepState.pending.rawValue
            step.waitReason = nil
            step.reviewAfter = nil
        }
        // 恢复即取消「到点检查」提醒（规格 §4.5：完成、恢复、改期或删除时取消旧提醒）
        if let revision = repository(in: repo).revision(id: revisionID) {
            TodoNotificationService.shared.cancelExecutionReviewReminder(taskID: revision.taskID, stepID: stepID)
        }
    }

    /// 保存用户停留记录（可选一行，规格 §4.6）
    func saveResumeNote(
        stepID: UUID,
        note: String,
        revisionID: UUID,
        operationID: String,
        sourceSurface: String,
        in repo: TodoRepository
    ) throws {
        let repository = repository(in: repo)
        guard let revision = repository.revision(id: revisionID) else { throw HoloTaskExecutionError.revisionNotFound }
        guard let step = repository.step(id: stepID, taskID: revision.taskID) else { throw HoloTaskExecutionError.stepNotFound }
        step.userResumeNote = note
        step.updatedAt = Date()
        Self.appendReceipt(
            in: repo.context,
            operationID: operationID,
            taskID: revision.taskID,
            revisionID: revisionID,
            stepID: stepID,
            command: "saveResumeNote",
            actor: .user,
            sourceSurface: sourceSurface,
            expectedStateVersion: step.stateVersion,
            before: nil,
            after: nil
        )
        do {
            try repo.context.save()
        } catch {
            repo.context.rollback()
            throw HoloTaskExecutionError.atomicSaveFailed(error.localizedDescription)
        }
        Self.afterCommit(repo: repo, taskChange: nil)
    }

    // MARK: - 局部修订（卡住了 → 新版本，历史不覆盖，规格 §5.3/§7.4）

    @discardableResult
    func revisePlan(
        taskID: UUID,
        proposal: HoloTaskExecutionProposal,
        expectedFingerprint: String,
        operationID: String,
        sourceSurface: String,
        in repo: TodoRepository
    ) throws -> HoloTaskExecutionRevision {
        let repository = repository(in: repo)
        let context = repo.context

        if let existing = repository.revision(operationID: operationID) { return existing }

        guard let revision = repository.activeRevision(taskID: taskID) else { throw HoloTaskExecutionError.noActivePlan }
        guard let topology = revision.topology else { throw HoloTaskExecutionError.revisionConflict }
        guard let task = repository.findTask(taskID), !task.completed else { throw HoloTaskExecutionError.taskUnavailable }

        if let current = repository.currentSnapshotFingerprint(taskID: taskID),
           current != expectedFingerprint {
            throw HoloTaskExecutionError.sourceStale
        }

        // 当前状态（含未完成判定）
        let resolution = HoloTaskExecutionPolicy.resolve(
            topology: topology,
            stepsByID: repository.steps(taskID: taskID).reduce(into: [UUID: HoloTaskExecutionPolicy.StepSnapshot]()) {
                $0[$1.id] = HoloTaskExecutionPolicy.StepSnapshot(id: $1.id, stateRaw: $1.stateRaw, stateVersion: $1.stateVersion)
            },
            checklistByID: repository.checklistByID(taskID: taskID),
            cursorStepID: nil
        )
        var completedIDs = Set<UUID>()
        for (id, state) in resolution.states {
            switch state {
            case .done, .group(true): completedIDs.insert(id)
            default: break
            }
        }

        let patch = proposal.patch
        let validation = HoloTaskExecutionPolicy.validate(HoloTaskExecutionPolicy.ValidationInput(
            mode: patch.mode,
            targetStepID: patch.targetStepID,
            newSteps: patch.newSteps,
            retainedStepIDs: patch.retainedStepIDs,
            retainTarget: patch.retainTarget,
            requirements: revision.outcomeContract?.requirements ?? [],
            existingTopology: topology,
            completedStepIDs: completedIDs
        ))
        let change: HoloTaskExecutionPolicy.PlanChange
        switch validation {
        case .success(let value): change = value
        case .failure(let error): throw error
        }

        let now = Date()

        if change.kind == .reviseLeafContent {
            // 同节点内容改写（未完成叶子）；原已完成节点不受影响
            guard let targetID = patch.targetStepID,
                  let step = repository.step(id: targetID, taskID: taskID) else {
                throw HoloTaskExecutionError.stepNotFound
            }
            step.actionText = patch.newSteps[0].action
            step.doneWhen = patch.newSteps[0].doneWhen
            step.updatedAt = now
            let newRevision = try appendRevision(
                for: task,
                basedOn: revision,
                topology: topology,
                contract: revision.outcomeContract,
                fingerprint: expectedFingerprint,
                operationID: operationID,
                source: .userAcceptedAI,
                at: now,
                in: context
            )
            Self.appendReceipt(
                in: context, operationID: operationID, taskID: taskID,
                revisionID: newRevision.id, stepID: targetID,
                command: "reviseLeaf", actor: .user, sourceSurface: sourceSurface,
                expectedStateVersion: step.stateVersion, before: nil,
                after: nil
            )
            try commit(context)
            Self.afterCommit(repo: repo, taskChange: nil)
            return newRevision
        }

        // ref → 真实 UUID（执行器分配，规格 §6.4）
        var assigned: [String: UUID] = [:]
        for step in patch.newSteps {
            assigned[step.ref] = UUID()
        }
        guard let targetID = patch.targetStepID,
              let target = topology.node(id: targetID) else {
            throw HoloTaskExecutionError.stepNotFound
        }

        let newTopology = HoloTaskExecutionPolicy.buildTopology(
            after: HoloTaskExecutionPolicy.ValidationInput(
                mode: patch.mode,
                targetStepID: patch.targetStepID,
                newSteps: patch.newSteps,
                retainedStepIDs: patch.retainedStepIDs,
                retainTarget: patch.retainTarget,
                requirements: revision.outcomeContract?.requirements ?? [],
                existingTopology: topology,
                completedStepIDs: completedIDs
            ),
            assignedIDs: assigned,
            target: target
        )

        let newRevision = try appendRevision(
            for: task,
            basedOn: revision,
            topology: newTopology,
            contract: revision.outcomeContract,
            fingerprint: expectedFingerprint,
            operationID: operationID,
            source: .userAcceptedAI,
            at: now,
            in: context
        )

        // 新节点建步骤实体；历史节点不动（无变化节点跨版本复用同一 ID）
        for node in newTopology.nodes where node.kind == .action && assigned.values.contains(node.id) {
            let ref = assigned.first { $0.value == node.id }?.key ?? ""
            let source = patch.newSteps.first { $0.ref == ref }
            let step = HoloTaskExecutionStep(entity: NSEntityDescription.entity(forEntityName: "HoloTaskExecutionStep", in: context)!, insertInto: context)
            step.id = node.id
            step.taskID = taskID
            step.originRevisionID = newRevision.id
            step.kindRaw = node.kindRaw
            step.actionText = source?.action
            step.doneWhen = source?.doneWhen
            step.stateRaw = HoloTaskExecutionStepState.pending.rawValue
            step.stateVersion = 1
            step.createdAt = now
            step.updatedAt = now
        }

        task.activeExecutionRevisionID = newRevision.id
        task.updatedAt = now

        Self.appendReceipt(
            in: context, operationID: operationID, taskID: taskID,
            revisionID: newRevision.id, stepID: nil,
            command: "revisePlan.\(patch.mode.rawValue)", actor: .user, sourceSurface: sourceSurface,
            expectedStateVersion: nil, before: nil,
            after: ["nodeCount": "\(newTopology.nodes.count)"]
        )
        try commit(context)
        Self.afterCommit(repo: repo, taskChange: nil)
        return newRevision
    }

    // MARK: - 结果确认（合并按钮 = 最后一步 + 根任务同一提交，规格 §8.2）

    /// 用户结果断言 → 同一事务保存最终步骤（可选）+ 根完成 + 回执。
    /// 由 HoloTaskCompletionCoordinator 的 3 秒到期回调触发；三秒内只是 pending UI。
    func requestCompleteOutcome(
        taskID: UUID,
        revisionID: UUID,
        finalStepID: UUID?,
        finalStepExpectedStateVersion: Int64?,
        userAssertion: String?,
        operationID: String,
        sourceSurface: String,
        in repo: TodoRepository
    ) throws {
        let repository = repository(in: repo)
        let context = repo.context
        if repository.receipt(operationID: operationID) != nil { return }

        guard let revision = repository.revision(id: revisionID), revision.taskID == taskID else {
            throw HoloTaskExecutionError.revisionNotFound
        }
        guard let task = repository.findTask(taskID) else { throw HoloTaskExecutionError.taskNotFound }

        // 1. 最终步骤（与根完成同一事务；失败全回滚）
        if let stepID = finalStepID {
            guard let step = repository.step(id: stepID, taskID: taskID) else { throw HoloTaskExecutionError.stepNotFound }
            guard step.state != .done else { throw HoloTaskExecutionError.stepAlreadyDone }
            if let expected = finalStepExpectedStateVersion, step.stateVersion != expected {
                throw HoloTaskExecutionError.stateVersionMismatch(expected: expected, actual: step.stateVersion)
            }
            step.stateRaw = HoloTaskExecutionStepState.done.rawValue
            step.completedAt = Date()
            step.stateVersion += 1
            step.stateChangedAt = Date()
            step.updatedAt = Date()
            Self.appendReceipt(
                in: context, operationID: "\(operationID)-step", taskID: taskID,
                revisionID: revisionID, stepID: stepID,
                command: "completeStep.final", actor: .user, sourceSurface: sourceSurface,
                expectedStateVersion: finalStepExpectedStateVersion, before: nil, after: nil
            )
        }

        // 2. 根完成：统一共享核心（不写步骤状态；完成核心在 managed 任务写来源回执）
        try TodoCompletionCore.complete(
            task,
            in: context,
            saveImmediately: false,
            sourceSurface: sourceSurface,
            operationID: operationID,
            outcomeAssertion: userAssertion
        )

        do {
            try context.save()
        } catch {
            context.rollback()
            logger.error("结果确认保存失败: \(error.localizedDescription, privacy: .public)")
            throw HoloTaskExecutionError.atomicSaveFailed(error.localizedDescription)
        }
        Self.afterCommit(repo: repo, taskChange: .completed, taskID: taskID)
    }

    /// 直接完成原任务（用户在现实中已办完，绕过建议过程，规格 §3.3-3）
    /// 未做的步骤不被补勾、不改历史（规格 §8.1）。
    func completeRootDirectly(
        taskID: UUID,
        sourceSurface: String,
        operationID: String,
        in repo: TodoRepository
    ) throws {
        let repository = repository(in: repo)
        if repository.receipt(operationID: operationID) != nil { return }
        guard let task = repository.findTask(taskID) else { throw HoloTaskExecutionError.taskNotFound }
        guard !task.completed else { return } // 已完成幂等成功
        try TodoCompletionCore.complete(
            task,
            in: repo.context,
            saveImmediately: true,
            sourceSurface: sourceSurface,
            operationID: operationID
        )
        Self.afterCommit(repo: repo, taskChange: .completed, taskID: taskID)
    }

    // MARK: - 内部：步骤命令公共通道（校验 + 变更 + 回执 + 一次保存）

    private func mutateStep(
        stepID: UUID,
        revisionID: UUID,
        expectedStateVersion: Int64,
        requireDone: Bool,
        command: String,
        sourceSurface: String,
        operationID: String,
        in repo: TodoRepository,
        mutate: (HoloTaskExecutionStep) -> Void
    ) throws {
        let repository = repository(in: repo)
        let context = repo.context

        guard let revision = repository.revision(id: revisionID), revision.deletedAt == nil else {
            throw HoloTaskExecutionError.revisionNotFound
        }
        let taskID = revision.taskID
        guard let step = repository.step(id: stepID, taskID: taskID) else { throw HoloTaskExecutionError.stepNotFound }

        // 节点必须仍在活动版本（引用一致性）
        guard let topology = revision.topology, topology.node(id: stepID) != nil else {
            throw HoloTaskExecutionError.stepNotInActiveRevision
        }
        guard step.kind == .action else { throw HoloTaskExecutionError.stepNotFound } // group/引用节点不可直接写状态

        // 状态前置
        if requireDone {
            guard step.state == .done else { throw HoloTaskExecutionError.stepNotFound }
        } else {
            if step.state == .done { throw HoloTaskExecutionError.stepAlreadyDone }
            if step.state == .waiting && command != "resumeStep" && command != "setWaiting" {
                throw HoloTaskExecutionError.stepWaiting
            }
        }

        // 依赖满足（被明确等待/移除/前置未完成都不能静默越过；规格 §7.4）
        if command == "completeStep" || command == "setWaiting" {
            guard let task = repository.findTask(taskID) else { throw HoloTaskExecutionError.taskNotFound }
            let resolution = HoloTaskExecutionPolicy.resolve(
                topology: topology,
                stepsByID: repository.steps(taskID: taskID).reduce(into: [UUID: HoloTaskExecutionPolicy.StepSnapshot]()) {
                    $0[$1.id] = HoloTaskExecutionPolicy.StepSnapshot(id: $1.id, stateRaw: $1.stateRaw, stateVersion: $1.stateVersion)
                },
                checklistByID: repository.checklistByID(taskID: taskID),
                cursorStepID: nil
            )
            let node = topology.node(id: stepID)
            let unsatisfied = (node?.dependsOn ?? []).filter { dep in
                switch resolution.states[dep] {
                case .done, .group(true): return false
                default: return true
                }
            }
            if let node, !unsatisfied.isEmpty, task.isExecutionManaged {
                throw HoloTaskExecutionError.dependencyNotSatisfied(dependsOn: unsatisfied)
            }
        }

        // 并发校验 token（跨设备撤回保护，规格 §8.3）
        if step.stateVersion != expectedStateVersion {
            throw HoloTaskExecutionError.stateVersionMismatch(expected: expectedStateVersion, actual: step.stateVersion)
        }

        let beforeState = step.stateRaw
        mutate(step)
        step.stateVersion += 1
        step.stateChangedAt = Date()
        step.updatedAt = Date()

        Self.appendReceipt(
            in: context,
            operationID: operationID,
            taskID: taskID,
            revisionID: revisionID,
            stepID: stepID,
            command: command,
            actor: .user,
            sourceSurface: sourceSurface,
            expectedStateVersion: expectedStateVersion,
            before: ["state": beforeState, "version": "\(expectedStateVersion)"],
            after: ["state": step.stateRaw, "version": "\(step.stateVersion)"]
        )

        do {
            try context.save()
        } catch {
            context.rollback()
            throw HoloTaskExecutionError.atomicSaveFailed(error.localizedDescription)
        }
        Self.afterCommit(repo: repo, taskChange: nil)
    }

    private func appendRevision(
        for task: TodoTask,
        basedOn parent: HoloTaskExecutionRevision,
        topology: HoloTaskExecutionTopology,
        contract: HoloTaskExecutionOutcomeContract?,
        fingerprint: String,
        operationID: String,
        source: HoloTaskExecutionPlanSource,
        at now: Date,
        in context: NSManagedObjectContext
    ) throws -> HoloTaskExecutionRevision {
        let revision = HoloTaskExecutionRevision(entity: NSEntityDescription.entity(forEntityName: "HoloTaskExecutionRevision", in: context)!, insertInto: context)
        revision.id = UUID()
        revision.taskID = task.id
        revision.originMatterID = parent.originMatterID
        revision.parentRevisionIDs = [parent.id]
        revision.operationID = operationID
        revision.schemaVersion = 1
        revision.sourceFingerprint = fingerprint
        revision.outcomeContract = contract
        revision.topology = topology
        revision.acceptedSource = source
        revision.createdAt = now
        return revision
    }

    private func commit(_ context: NSManagedObjectContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw HoloTaskExecutionError.atomicSaveFailed(error.localizedDescription)
        }
    }

    private func guardAdoptable(_ task: TodoTask) throws {
        // 首版边界（规格 §13.1）：活动、非重复、未完成
        guard !task.completed, task.completedAt == nil, task.deletedAt == nil, !task.archived else {
            throw HoloTaskExecutionError.taskUnavailable
        }
        guard task.repeatRule == nil else {
            throw HoloTaskExecutionError.taskUnavailable
        }
    }

    // MARK: - 内部静态工具

    nonisolated private static func nextRequirementID(used: inout Set<String>) -> String {
        var index = 1
        while used.contains("req-\(index)") { index += 1 }
        let id = "req-\(index)"
        used.insert(id)
        return id
    }

    /// 采纳拓扑构建：动作节点 + 未完成清单引用节点（收尾节点，规格 §3.4）
    nonisolated private static func buildAdoptionTopology(
        steps: [HoloTaskExecutionManualStep],
        checklist: [CheckItem],
        requirementIDForChecklistItem: (UUID) -> String?
    ) throws -> [HoloTaskExecutionTopologyNode] {
        guard (1...HoloTaskExecutionLimits.maxInitialLeaves).contains(steps.count) else {
            throw HoloTaskExecutionError.limitsExceeded(reason: "初始叶子必须在 1...\(HoloTaskExecutionLimits.maxInitialLeaves)")
        }
        var nodes: [HoloTaskExecutionTopologyNode] = []
        var order = 0
        for step in steps {
            guard !step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !step.doneWhen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HoloTaskExecutionError.invalidProposal(reason: "步骤缺少动作或完成条件")
            }
            nodes.append(HoloTaskExecutionTopologyNode(
                id: step.id,
                kindRaw: HoloTaskExecutionStepKind.action.rawValue,
                stableOrder: order,
                required: true,
                dependsOn: [],
                coversRequirementIDs: step.coversRequirementIDs,
                parentGroupID: nil,
                sourceCheckItemID: nil,
                roleRaw: step.role.rawValue
            ))
            order += 1
        }
        for item in checklist where !item.isChecked {
            nodes.append(HoloTaskExecutionTopologyNode(
                id: UUID(),
                kindRaw: HoloTaskExecutionStepKind.sourceCheckItemReference.rawValue,
                stableOrder: order,
                required: true,
                dependsOn: [],
                coversRequirementIDs: [requirementIDForChecklistItem(item.id)].compactMap { $0 },
                parentGroupID: nil,
                sourceCheckItemID: item.id,
                roleRaw: nil
            ))
            order += 1
        }
        return nodes
    }

    /// 最小来源回执（规格 §7.2-D；不存模型对话/附件/隐私内容）
    nonisolated static func appendReceipt(
        in context: NSManagedObjectContext,
        operationID: String,
        taskID: UUID,
        revisionID: UUID?,
        stepID: UUID?,
        command: String,
        actor: HoloTaskExecutionActor,
        sourceSurface: String,
        expectedStateVersion: Int64?,
        before: [String: String]?,
        after: [String: String]?
    ) {
        let receipt = HoloTaskExecutionReceipt(entity: NSEntityDescription.entity(forEntityName: "HoloTaskExecutionReceipt", in: context)!, insertInto: context)
        receipt.id = UUID()
        receipt.operationID = operationID
        receipt.taskID = taskID
        receipt.revisionID = revisionID
        receipt.stepID = stepID
        receipt.commandRaw = command
        receipt.actorRaw = actor.rawValue
        receipt.sourceSurface = sourceSurface
        receipt.expectedStateVersion = expectedStateVersion.map { NSNumber(value: $0) }
        receipt.beforeStateJSON = before.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        receipt.afterStateJSON = after.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        receipt.createdAt = Date()
    }

    /// 提交成功后的统一广播（规格 §7.4：一次命令一次刷新，复用现有链路）
    nonisolated private static func afterCommit(repo: TodoRepository, taskChange: HoloTaskChangeKind?, taskID: UUID? = nil) {
        Task { @MainActor in
            repo.loadActiveTasks()
            repo.notifyDataChange()
            if let taskChange, let taskID {
                repo.notifyTaskChange(taskChange, taskId: taskID)
            }
        }
    }
}
