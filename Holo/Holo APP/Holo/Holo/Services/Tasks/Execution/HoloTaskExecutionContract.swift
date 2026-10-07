//
//  HoloTaskExecutionContract.swift
//  Holo
//
//  任务「分步推进」契约与状态定义（2026-09-25 实施规格 §3/§5.4/§6.4/§7.3）
//
//  本文件为纯 Foundation 类型，App 与 Widget 共享编译（无 SwiftUI/主 App 单例依赖）。
//  三层结果模型：Matter（沿用）→ 原任务 TodoTask（根结果事实）→ 执行步骤（动作事实）。
//  四条完成不变量的落点：准备≠结果（覆盖校验）；步骤完成⇒readyToConfirm 不⇒根完成
//  （Policy）；用户断言才完成根（Service）；根完成不反证步骤（根完成不写步骤状态）。
//

import Foundation
import CryptoKit

// MARK: - 错误（代码必须拒绝的提案形态，规格 §5.4）

nonisolated enum HoloTaskExecutionError: Error, LocalizedError, Equatable {
    case taskNotFound
    case taskUnavailable                    // 已删除/归档/重复任务等不支持分步
    case alreadyManaged                     // 已有活动计划（重复采纳）
    case noActivePlan
    case revisionNotFound
    case revisionConflict                   // 版本链分叉未解决或指针失效
    case stepNotFound
    case stepNotInActiveRevision            // 节点不在当前活动版本
    case stepAlreadyDone
    case stepCancelled                      // 节点已移出活动范围
    case stepWaiting                        // 节点被明确等待
    case dependencyNotSatisfied(dependsOn: [UUID])
    case stateVersionMismatch(expected: Int64, actual: Int64)   // 跨设备并发保护
    case operationReplayed(operationID: String)                 // 同 operationID 幂等命中
    case invalidProposal(reason: String)    // 校验拒绝的总入口
    case sourceStale                        // 候选建立后源已变化（指纹不匹配）
    case contractExpired                    // 契约依据失效，需复核
    case limitsExceeded(reason: String)
    case atomicSaveFailed(String)

    var errorDescription: String? {
        switch self {
        case .taskNotFound: return "任务不存在"
        case .taskUnavailable: return "该任务暂不支持分步推进"
        case .alreadyManaged: return "这个任务已经有推进计划"
        case .noActivePlan: return "还没有推进计划"
        case .revisionNotFound: return "计划版本不存在"
        case .revisionConflict: return "计划在其他设备上有修改，需要先复核"
        case .stepNotFound: return "步骤不存在"
        case .stepNotInActiveRevision: return "步骤不在当前计划里"
        case .stepAlreadyDone: return "这步已经完成了"
        case .stepCancelled: return "这步已从计划移除"
        case .stepWaiting: return "这步正在等待中，先恢复再完成"
        case .dependencyNotSatisfied: return "还有前置步骤没完成"
        case .stateVersionMismatch: return "状态已在其他设备更新"
        case .operationReplayed: return "该操作已执行过"
        case .invalidProposal(let reason): return "方案无法采纳：\(reason)"
        case .sourceStale: return "任务内容已变化，请按当前内容重新生成"
        case .contractExpired: return "结果条件需要复核"
        case .limitsExceeded(let reason): return "超出上限：\(reason)"
        case .atomicSaveFailed: return "保存失败，未做任何更改"
        }
    }
}

// MARK: - 结果契约（Outcome Contract，规格 §3.2）

/// 结果要求来源（优先级：userStated > taskBody/checklist > matterConfirmed；aiSuggestion 必须标建议）
nonisolated enum HoloTaskExecutionRequirementSource: String, Codable {
    case userStated
    case taskBody
    case checklist
    case matterConfirmed
    case aiSuggestion
}

nonisolated struct HoloTaskExecutionRequirement: Codable, Equatable, Identifiable {
    /// 稳定要求 ID（如 "req-1"）；提案中的 coversRequirementIDs 引用它
    var id: String
    var content: String
    var sourceRaw: String
    var sourceID: String?

    var source: HoloTaskExecutionRequirementSource {
        get { HoloTaskExecutionRequirementSource(rawValue: sourceRaw) ?? .taskBody }
        set { sourceRaw = newValue.rawValue }
    }

    init(id: String, content: String, source: HoloTaskExecutionRequirementSource, sourceID: String? = nil) {
        self.id = id
        self.content = content
        self.sourceRaw = source.rawValue
        self.sourceID = sourceID
    }
}

/// 已确认的范围变化（增减范围必须用户采纳；默认不得缩减，规格 §3.2）
nonisolated struct HoloTaskExecutionScopeChange: Codable, Equatable {
    var summary: String
    /// 受影响的要求 ID；缩减时对应要求从活动集合移除
    var requirementIDs: [String]
    var isReduction: Bool
}

nonisolated struct HoloTaskExecutionOutcomeContract: Codable, Equatable {
    /// 一句人能理解的结果
    var outcomeSummary: String
    /// 最后如何由用户确认结果（不默认索要附件）
    var verificationPrompt: String
    var requirements: [HoloTaskExecutionRequirement]
    /// 契约依据指纹：只覆盖结果义务相关内容；勾步骤/勾清单不使其失效（规格 §7.5）
    var contractBasisFingerprint: String
    var scopeChanges: [HoloTaskExecutionScopeChange]
}

// MARK: - 拓扑（topologyJSON，不存完成状态）

nonisolated enum HoloTaskExecutionStepRole: String, Codable {
    case preparation
    case execution
    case verification
}

nonisolated struct HoloTaskExecutionTopologyNode: Codable, Equatable {
    var id: UUID
    /// HoloTaskExecutionStepKind raw（action / sourceCheckItemReference / group）
    var kindRaw: String
    /// 当前版本内的稳定顺序（展示与本地选择排序依据）
    var stableOrder: Int
    /// 必要步骤不阻塞结果确认的例外是 optional；required 改 optional 属范围变化
    var required: Bool
    var dependsOn: [UUID]
    var coversRequirementIDs: [String]
    var parentGroupID: UUID?
    var sourceCheckItemID: UUID?
    var roleRaw: String?

    var kind: HoloTaskExecutionStepKind {
        get { HoloTaskExecutionStepKind(rawValue: kindRaw) ?? .action }
        set { kindRaw = newValue.rawValue }
    }
    var role: HoloTaskExecutionStepRole? {
        get { roleRaw.flatMap(HoloTaskExecutionStepRole.init(rawValue:)) }
        set { roleRaw = newValue?.rawValue }
    }
}

nonisolated struct HoloTaskExecutionTopology: Codable, Equatable {
    var nodes: [HoloTaskExecutionTopologyNode]

    func node(id: UUID) -> HoloTaskExecutionTopologyNode? {
        nodes.first { $0.id == id }
    }

    /// 活动（未被移除引用的）action 节点，按稳定顺序
    func actionNodes() -> [HoloTaskExecutionTopologyNode] {
        nodes.filter { $0.kind == .action }
    }
}

// MARK: - AI 提案契约（规格 §6.4；客户端生成真实实体 ID，模型只能引用输入已有 ID 或局部 ref）

/// 补丁方式：A 完整细化 / B 前置准备保义务 / C 局部改写未完成叶子
nonisolated enum HoloTaskExecutionPatchMode: String, Codable {
    case refineTarget          // 目标动作变分组，原义务由子步骤推导覆盖
    case prependPreparation    // 新增准备动作 + 保留原动作（残余义务不丢）
    case reviseLeaf            // 改写当前未完成叶子的内容
}

nonisolated struct HoloTaskExecutionNewStep: Codable, Equatable {
    /// 候选局部 ref（"s1"…）；执行器校验后分配真实 UUID
    var ref: String
    var action: String
    var doneWhen: String
    var roleRaw: String?
    /// 依赖其他新步骤用 ref；引用已有步骤在 targetStepID 语义内表达
    var dependsOnRefs: [String]
    var coversRequirementIDs: [String]

    var role: HoloTaskExecutionStepRole? {
        get { roleRaw.flatMap(HoloTaskExecutionStepRole.init(rawValue:)) }
        set { roleRaw = newValue?.rawValue }
    }
}

nonisolated struct HoloTaskExecutionProposalPatch: Codable, Equatable {
    var mode: HoloTaskExecutionPatchMode
    /// refine/revise 的目标节点；prepend 时为要前置到的节点
    var targetStepID: UUID?
    var newSteps: [HoloTaskExecutionNewStep]
    /// refine 后保留原样的既有节点（ID 不变，完成历史保留）
    var retainedStepIDs: [UUID]
    /// prepend：保留目标节点为剩余义务
    var retainTarget: Bool
    /// refine 可整体声明结果要求集合（含来源）；prepend/revise 不改契约
    var requirements: [HoloTaskExecutionRequirement]?

    var modeRawString: HoloTaskExecutionPatchMode { mode }
}

/// AI 返回联合类型：proposal / clarification / cannotHelp（kind 字段区分）
nonisolated struct HoloTaskExecutionProposal: Codable, Equatable {
    /// "proposal"
    var kind: String
    var outcomeSummary: String
    var verificationPrompt: String
    var patch: HoloTaskExecutionProposalPatch
    var scopeChanges: [HoloTaskExecutionScopeChange]
    /// 结果要求声明（refine 可整体声明；appendPreparation 不改契约）
    var requirements: [HoloTaskExecutionRequirement]?
}

nonisolated struct HoloTaskExecutionClarification: Codable, Equatable {
    var kind: String
    var question: String
    var suggestedAnswers: [String]
}

nonisolated struct HoloTaskExecutionCannotHelp: Codable, Equatable {
    var kind: String
    var reason: String
    var suggestedManualAction: String?
}

/// 解码后的响应联合
nonisolated enum HoloTaskExecutionAIOutcome: Equatable {
    case proposal(HoloTaskExecutionProposal)
    case clarification(HoloTaskExecutionClarification)
    case cannotHelp(HoloTaskExecutionCannotHelp)
}

// MARK: - 手工计划输入（无 AI 时的建计划入口；P1 验收与降级路径共用）

nonisolated struct HoloTaskExecutionManualStep: Identifiable {
    let id = UUID()
    var action: String
    var doneWhen: String
    var role: HoloTaskExecutionStepRole = .execution
    var sourceCheckItemID: UUID?
    /// 覆盖的结果要求（采纳的必要条件，规格 §5.4）
    var coversRequirementIDs: [String] = []
}

// MARK: - 派生视图状态（规格 §7.3）

nonisolated enum HoloTaskExecutionDerivedState: Equatable {
    case absent                 // 未采纳方案
    case ready                  // 有可做叶子
    case waiting                // 无可做叶子且有真实等待
    case needsReview            // 来源变动/引用缺失/分叉
    case syncing                // 版本引用的节点尚未同步完整
    case readyToConfirm         // 必要叶子满足且契约有效
    case rootCompleted          // 根任务已完成
    case unavailable            // 删除/归档/不支持
}

// MARK: - 粒度限制（规格 §5.5）

nonisolated enum HoloTaskExecutionLimits {
    static let maxInitialLeaves = 7
    static let typicalMinLeaves = 2
    static let typicalMaxLeaves = 5
    static let maxActiveLeaves = 24
    static let maxDepth = 3
}

// MARK: - 指纹（规格 §7.5）

nonisolated enum HoloTaskExecutionFingerprint {

    /// 候选快照指纹：勾一步就过期（拒绝迟到候选），但不影响已采纳计划有效性。
    /// 覆盖：taskID、标题/说明、约束（截止）、原清单 ID/内容/勾选状态、活动 revision、目标步骤 stateVersion。
    static func snapshot(
        taskID: UUID,
        title: String,
        desc: String?,
        dueDate: Date?,
        checklist: [HoloTaskExecutionChecklistItem],
        activeRevisionID: UUID?,
        targetStepStateVersions: [UUID: Int64]
    ) -> String {
        let payload = FingerprintPayload(
            scope: "proposalSnapshot",
            taskID: taskID.uuidString,
            title: title,
            desc: desc ?? "",
            dueDate: dueDate.map { "\($0.timeIntervalSince1970)" } ?? "",
            checklist: checklist.map { $0.fingerprintComponent },
            activeRevisionID: activeRevisionID?.uuidString ?? "",
            stepVersions: targetStepStateVersions.map { "\($0.key.uuidString)=\($0.value)" }.sorted()
        )
        return sha256(of: payload)
    }

    /// 契约依据指纹：只覆盖结果义务相关内容；不含步骤完成状态/普通勾选/等待/游标。
    static func contractBasis(
        taskID: UUID,
        title: String,
        desc: String?,
        checklist: [HoloTaskExecutionChecklistItem]
    ) -> String {
        let payload = FingerprintPayload(
            scope: "contractBasis",
            taskID: taskID.uuidString,
            title: title,
            desc: desc ?? "",
            dueDate: "",
            checklist: checklist.map { "\($0.id.uuidString)|\($0.title)|necessity=\($0.isRequired ? 1 : 0)" },
            activeRevisionID: "",
            stepVersions: []
        )
        return sha256(of: payload)
    }

    struct FingerprintPayload: Codable {
        var scope: String
        var taskID: String
        var title: String
        var desc: String
        var dueDate: String
        var checklist: [String]
        var activeRevisionID: String
        var stepVersions: [String]
    }

    /// 规范化 JSON（sortedKeys）+ SHA256，稳定可重现
    static func sha256(of payload: FingerprintPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 指纹输入用的原清单项快照（真实 CheckItem 的投影）
nonisolated struct HoloTaskExecutionChecklistItem: Identifiable, Equatable {
    var id: UUID
    var title: String
    var isChecked: Bool
    /// 是否被结果契约声明为必要义务
    var isRequired: Bool

    var fingerprintComponent: String {
        "\(id.uuidString)|\(title)|checked=\(isChecked ? 1 : 0)|necessity=\(isRequired ? 1 : 0)"
    }
}
