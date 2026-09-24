//
//  HoloTaskExecutionPolicy.swift
//  Holo
//
//  分步推进纯规则层（2026-09-25 实施规格 §5.4/§6.2/§7.3）
//  无 IO、无单例、可单测：叶子状态派生、下一步选择、提案校验、覆盖与上限校验。
//  完成不变量在此落地：步骤完成 ⇒ readyToConfirm；不推出根完成。
//

import Foundation

nonisolated enum HoloTaskExecutionPolicy {

    // MARK: - 叶子有效状态（派生，规格 §7.2-C）

    enum EffectiveState: Equatable {
        /// action 未完成
        case pending
        /// action 已完成
        case done
        /// action 被明确等待
        case waiting
        /// 引用的原清单项已不存在（brokenReference，不是 done）
        case brokenReference
        /// 分组：状态纯派生
        case group(satisfied: Bool)
    }

    /// 派生单个节点的有效状态。
    /// - checklist：真实清单勾选状态（引用节点的唯一事实源）
    static func effectiveState(
        node: HoloTaskExecutionTopologyNode,
        step: StepSnapshot?,
        checklistByID: [UUID: Bool]
    ) -> EffectiveState {
        switch node.kind {
        case .group:
            return .group(satisfied: false) // 由 deriveStates 聚合后覆写
        case .sourceCheckItemReference:
            guard let itemID = node.sourceCheckItemID, let checked = checklistByID[itemID] else {
                return .brokenReference
            }
            return checked ? .done : .pending
        case .action:
            guard let step else { return .pending } // 云端节点未到达由 syncing 判定，不猜
            switch step.state {
            case .done: return .done
            case .waiting: return .waiting
            case .pending: return .pending
            }
        }
    }

    struct StepSnapshot {
        let id: UUID
        let stateRaw: String
        let stateVersion: Int64

        var state: HoloTaskExecutionStepState {
            HoloTaskExecutionStepState(rawValue: stateRaw) ?? .pending
        }
    }

    // MARK: - 全量派生 + 下一步选择（规格 §6.2）

    /// 计算活动拓扑内全部节点的有效状态与可做集合。
    /// 返回 nil 表示拓扑不完整（syncing：节点实体缺失），由调用方呈现同步态。
    static func resolve(
        topology: HoloTaskExecutionTopology,
        stepsByID: [UUID: StepSnapshot],
        checklistByID: [UUID: Bool],
        cursorStepID: UUID?
    ) -> Resolution {
        var states: [UUID: EffectiveState] = [:]
        var missingNodes: [UUID] = []

        for node in topology.nodes where node.kind != .group {
            if node.kind == .action, stepsByID[node.id] == nil {
                missingNodes.append(node.id)
                continue
            }
            states[node.id] = effectiveState(node: node, step: stepsByID[node.id], checklistByID: checklistByID)
        }

        // 分组自底向上聚合（拓扑深度 ≤3，直接多轮折叠）
        for _ in 0..<(topology.nodes.count + 1) {
            var changed = false
            for node in topology.nodes where node.kind == .group && states[node.id] == nil {
                let children = topology.nodes.filter { $0.parentGroupID == node.id }
                let known = children.compactMap { states[$0.id] }
                guard known.count == children.count, !children.isEmpty else { continue }
                let satisfied = children.allSatisfy {
                    guard case let .group(sat) = states[$0.id] ?? .group(satisfied: false) else {
                        return false
                    }
                    return sat
                }
                states[node.id] = .group(satisfied: satisfied)
                changed = true
            }
            if !changed { break }
        }

        if !missingNodes.isEmpty {
            return Resolution(state: .syncing, states: states, actionableIDs: [], missingNodeIDs: missingNodes)
        }

        // 可做叶子：pending、依赖全部满足；并行步骤不因显示顺序被制造成强依赖
        var actionable: [UUID] = []
        for node in topology.nodes {
            guard node.kind == .action, case .pending? = states[node.id] else { continue }
            let depsSatisfied = node.dependsOn.allSatisfy { depID in
                switch states[depID] {
                case .done, .group(true): return true
                default: return false
                }
            }
            if depsSatisfied { actionable.append(node.id) }
        }

        // 游标优先（UI 偏好，不是业务事实；失效则按 stableOrder、UUID 稳定序取第一项）
        var ordered = actionable
        ordered.sort {
            let l = topology.node(id: $0), r = topology.node(id: $1)
            guard let l, let r else { return false }
            if l.stableOrder != r.stableOrder { return l.stableOrder < r.stableOrder }
            return l.id.uuidString < r.id.uuidString
        }
        if let cursor = cursorStepID, ordered.contains(cursor) {
            ordered.removeAll { $0 == cursor }
            ordered.insert(cursor, at: 0)
        }

        return Resolution(state: .ready, states: states, actionableIDs: ordered, missingNodeIDs: [])
    }

    struct Resolution {
        var state: HoloTaskExecutionDerivedState
        var states: [UUID: EffectiveState]
        var actionableIDs: [UUID]
        var missingNodeIDs: [UUID]
    }

    /// 汇总派生视图状态（规格 §7.3；优先级 syncing > needsReview > readyToConfirm > ready > waiting）
    static func derivedState(
        resolution: Resolution,
        topology: HoloTaskExecutionTopology,
        taskCompleted: Bool,
        contractValid: Bool
    ) -> HoloTaskExecutionDerivedState {
        if taskCompleted { return .rootCompleted }
        if resolution.state == .syncing { return .syncing }
        if !contractValid { return .needsReview }

        let requiredNodes = topology.nodes.filter { $0.required && $0.kind != .group }
        let requiredSatisfied = requiredNodes.allSatisfy { node in
            switch resolution.states[node.id] {
            case .done, .group(true): return true
            default: return false
            }
        }
        if requiredSatisfied && !requiredNodes.isEmpty { return .readyToConfirm }
        if requiredNodes.isEmpty { return .needsReview } // 无必要节点的计划视为契约缺口

        if !resolution.actionableIDs.isEmpty { return .ready }

        let hasWaiting = requiredNodes.contains {
            if case .waiting = resolution.states[$0.id] { return true }
            return false
        }
        return hasWaiting ? .waiting : .needsReview
    }

    // MARK: - 覆盖校验（规格 §5.4：覆盖映射是必要条件）

    /// 每一项要求必须被至少一个活动节点覆盖
    static func coverageGaps(
        requirements: [HoloTaskExecutionRequirement],
        topology: HoloTaskExecutionTopology
    ) -> [String] {
        let covered = Set(topology.nodes.flatMap { $0.coversRequirementIDs })
        return requirements.map(\.id).filter { !covered.contains($0) }
    }

    // MARK: - 上限（规格 §5.5）

    static func activeLeafCount(topology: HoloTaskExecutionTopology) -> Int {
        topology.nodes.filter { $0.kind != .group }.count
    }

    // MARK: - 提案校验（硬规则，规格 §5.4）

    struct ValidationInput {
        let mode: HoloTaskExecutionPatchMode
        let targetStepID: UUID?
        let newSteps: [HoloTaskExecutionNewStep]
        let retainedStepIDs: [UUID]
        let retainTarget: Bool
        let requirements: [HoloTaskExecutionRequirement]
        let existingTopology: HoloTaskExecutionTopology
        /// 校验时该节点是否已完成（modifyCompletedLeaf 判定）
        let completedStepIDs: Set<UUID>
    }

    /// 校验失败返回具体错误；通过返回补齐依赖接线后的拓扑变更说明。
    /// 不落库——落库由 Service 在同一事务内完成。
    static func validate(_ input: ValidationInput) -> Result<PlanChange, HoloTaskExecutionError> {
        // 目标节点合法性
        switch input.mode {
        case .refineTarget, .prependPreparation, .reviseLeaf:
            guard let targetID = input.targetStepID,
                  let target = input.existingTopology.node(id: targetID) else {
                return .failure(.invalidProposal(reason: "未知目标节点"))
            }
            guard target.kind == .action else {
                return .failure(.invalidProposal(reason: "目标不是可执行动作"))
            }
            if input.mode != .refineTarget {
                // refine 允许对未完成分组整体细化之外，只允许未完成叶子为目标
                guard input.completedStepIDs.contains(targetID) == false else {
                    return .failure(.invalidProposal(reason: "不能修改已完成的步骤"))
                }
            }
        }

        // reviseLeaf：单步改写，不新增节点
        if input.mode == .reviseLeaf {
            guard input.newSteps.count == 1, input.retainedStepIDs.isEmpty else {
                return .failure(.invalidProposal(reason: "改写只接受一个步骤"))
            }
            let step = input.newSteps[0]
            guard !step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !step.doneWhen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.invalidProposal(reason: "步骤缺少动作或完成条件"))
            }
            return .success(PlanChange(kind: .reviseLeafContent))
        }

        // 新步骤内容校验
        guard !input.newSteps.isEmpty else {
            return .failure(.invalidProposal(reason: "没有新步骤"))
        }
        guard input.newSteps.count <= HoloTaskExecutionLimits.maxInitialLeaves else {
            return .failure(.limitsExceeded(reason: "单次最多 \(HoloTaskExecutionLimits.maxInitialLeaves) 个初始叶子"))
        }
        var seenRefs = Set<String>()
        for step in input.newSteps {
            guard !step.ref.isEmpty, !seenRefs.contains(step.ref) else {
                return .failure(.invalidProposal(reason: "重复节点"))
            }
            seenRefs.insert(step.ref)
            guard !step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !step.doneWhen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.invalidProposal(reason: "步骤缺少动作或完成条件"))
            }
        }

        // 依赖自指/未知 ref（依赖循环在接线后统一检测）
        let refToNew = Dictionary(input.newSteps.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        for step in input.newSteps {
            for dep in step.dependsOnRefs where refToNew[dep] == nil {
                return .failure(.invalidProposal(reason: "未知依赖 ref: \(dep)"))
            }
            if step.dependsOnRefs.contains(step.ref) {
                return .failure(.invalidProposal(reason: "依赖自指"))
            }
        }

        // prepend 必须保留目标义务，不得偷偷缩减
        if input.mode == .prependPreparation {
            guard input.retainTarget else {
                return .failure(.invalidProposal(reason: "准备动作不能替换原结果义务"))
            }
            let coveringNew = input.newSteps.contains { !$0.coversRequirementIDs.isEmpty }
            if coveringNew {
                return .failure(.invalidProposal(reason: "准备动作不声明结果覆盖"))
            }
        }

        // retained 节点必须真实存在
        for id in input.retainedStepIDs where input.existingTopology.node(id: id) == nil {
            return .failure(.invalidProposal(reason: "未知保留节点"))
        }

        // 上限：改动后活动叶子数
        let addedLeaves = input.mode == .reviseLeaf ? 0 : input.newSteps.count
        let removedLeaves = input.mode == .refineTarget ? 1 : 0 // 目标叶子变分组
        let after = activeLeafCount(topology: input.existingTopology) + addedLeaves - removedLeaves
        guard after <= HoloTaskExecutionLimits.maxActiveLeaves else {
            return .failure(.limitsExceeded(reason: "活动步骤上限 \(HoloTaskExecutionLimits.maxActiveLeaves)"))
        }

        return .success(PlanChange(kind: input.mode == .refineTarget ? .refine : .prepend))
    }

    /// 接线后的新拓扑（validate 通过后由 Service 调用；同规则生成节点与依赖）
    static func buildTopology(
        after input: ValidationInput,
        assignedIDs: [String: UUID],
        target: HoloTaskExecutionTopologyNode
    ) -> HoloTaskExecutionTopology {
        var nodes = input.existingTopology.nodes
        let targetIndex = nodes.firstIndex { $0.id == target.id }

        let newNodes: [HoloTaskExecutionTopologyNode] = input.newSteps.enumerated().map { index, step in
            let id = assignedIDs[step.ref] ?? UUID()
            let dependsOn = step.dependsOnRefs.compactMap { assignedIDs[$0] }
            return HoloTaskExecutionTopologyNode(
                id: id,
                kindRaw: HoloTaskExecutionStepKind.action.rawValue,
                stableOrder: (target.stableOrder) + index,
                required: target.required,
                dependsOn: dependsOn,
                coversRequirementIDs: input.mode == .prependPreparation ? [] : step.coversRequirementIDs,
                parentGroupID: input.mode == .refineTarget ? target.id : target.parentGroupID,
                sourceCheckItemID: nil,
                roleRaw: step.roleRaw
            )
        }

        switch input.mode {
        case .refineTarget:
            // 目标节点变分组：完成由必要子步骤推导，覆盖关系随组保留
            if let idx = targetIndex {
                nodes[idx].kindRaw = HoloTaskExecutionStepKind.group.rawValue
            }
            nodes.append(contentsOf: newNodes)
        case .prependPreparation:
            // 新准备步骤排在目标前，目标依赖链条最后一个准备步骤
            if let idx = targetIndex {
                nodes[idx].dependsOn.append(newNodes.last?.id ?? UUID())
            }
            if let idx = targetIndex {
                nodes.insert(contentsOf: newNodes, at: idx)
            } else {
                nodes.append(contentsOf: newNodes)
            }
        case .reviseLeaf:
            break
        }

        normalizeOrders(&nodes)
        let topology = HoloTaskExecutionTopology(nodes: nodes)
        precondition(detectCycle(topology) == nil, "依赖循环必须被拒绝，不应到达这里")
        return topology
    }

    /// 稳定顺序重排（活动节点 0...N-1）
    static func normalizeOrders(_ nodes: inout [HoloTaskExecutionTopologyNode]) {
        var order = 0
        for idx in nodes.indices {
            nodes[idx].stableOrder = order
            order += 1
        }
    }

    /// 依赖循环检测；返回形成环的节点 ID（无环返回 nil）
    static func detectCycle(_ topology: HoloTaskExecutionTopology) -> UUID? {
        var state: [UUID: Int] = [:] // 0=未访问 1=在栈 2=完成
        func dfs(_ id: UUID) -> UUID? {
            switch state[id] {
            case 1: return id
            case 2: return nil
            default: break
            }
            state[id] = 1
            if let target = topology.node(id: id) {
                for dep in target.dependsOn {
                    if let cycle = dfs(dep) { return cycle }
                }
            }
            state[id] = 2
            return nil
        }
        for node in topology.nodes {
            if let cycle = dfs(node.id) { return cycle }
        }
        return nil
    }

    // MARK: - 结果

    struct PlanChange: Equatable {
        enum Kind: Equatable {
            case refine
            case prepend
            case reviseLeafContent
        }
        var kind: Kind
    }
}
