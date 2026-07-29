//
//  HoloAgentLineage.swift
//  Holo
//
//  连续追问的 lineage（血统）契约。
//
//  每次 child Job 创建时冻结一份 lineage，记录它在分析链中的位置：
//  - rootJobID / rootResultID：分析链最初的那份分析
//  - parentJobID / parentResultID：当前这一轮直接承接的结果
//  - relation：本轮追问的关系类型
//  - lineageDepth：在链中的深度（root = 0），上限 20
//
//  lineage 一旦随 initial Checkpoint commit，重试、恢复和模型输出都不能改写。
//  旧 Job / Result 没有 lineage 字段时按独立 root（lineage = nil，depth = 0）处理，
//  保证旧数据可解码、可恢复、不阻塞迁移。
//

import Foundation

/// 追问关系闭集。Phase 1 只用到 explain（显式追问统一标记）；
/// Phase 3 起按确定性规则和专用 Router 区分全部类型。
nonisolated enum HoloAgentFollowUpRelation: String, Codable, CaseIterable, Sendable {
    /// 解释已有结论（沿用父 Evidence，默认不重查）
    case explain
    /// 深挖某条结论或建议（复用相关 Evidence，只补缺失）
    case drillDown
    /// 纠正统计口径（保留父结果，重建 AnswerTask）
    case correct
    /// 更换时间范围、领域或维度（继承主题，不复用数值）
    case changeScope
    /// 跨领域补查（对齐快照，默认只补查新领域）
    case crossDomain
    /// 从 Result 发起执行（只解析 Recommendation ID，走确认卡）
    case executeFromResult
    /// 新话题（不继承父 Result）
    case newTopic
    /// 模糊，无法确定关系（不自动继承，需澄清）
    case ambiguous

    /// 是否属于追问（需要继承父 Result 的结构化事实）。
    var isFollowUp: Bool {
        switch self {
        case .explain, .drillDown, .correct, .changeScope, .crossDomain, .executeFromResult:
            return true
        case .newTopic, .ambiguous:
            return false
        }
    }

    /// 卡片角标 / 锚定条用的短文案。Phase 1 只有 explain 会展示；
    /// 其余为 Phase 3 Router 产出后预留，文案先占位。
    var shortLabel: String {
        switch self {
        case .explain:           return "继续追问"
        case .drillDown:         return "深挖"
        case .correct:           return "口径纠正"
        case .changeScope:       return "范围调整"
        case .crossDomain:       return "跨域补查"
        case .executeFromResult: return "发起执行"
        case .newTopic:          return "新话题"
        case .ambiguous:         return "继续"
        }
    }
}

/// lineage 最大深度。达到后把当前最小可信 Snapshot 滚动为新 root。
nonisolated enum HoloAgentLineageLimit {
    static let maxDepth = 20
}

/// Job 和 Result 共用的 lineage 模型。
nonisolated struct HoloAgentLineage: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var rootJobID: String
    var rootResultID: String
    var parentJobID: String
    var parentResultID: String
    var relationRawValue: String
    var lineageDepth: Int

    var relation: HoloAgentFollowUpRelation {
        HoloAgentFollowUpRelation(rawValue: relationRawValue) ?? .ambiguous
    }

    /// 从 parent lineage 构造 child lineage。
    /// - parent 有 lineage 时传播 root，depth + 1；
    /// - parent 无 lineage（legacy root）时，root 就是 parent，depth = 1；
    /// - depth 达到上限时仍然构造，调用方应在达到上限时滚动为新 root。
    init(
        parentJobID: String,
        parentResultID: String,
        relation: HoloAgentFollowUpRelation,
        parentLineage: HoloAgentLineage?
    ) {
        self.schemaVersion = 1
        if let parentLineage {
            self.rootJobID = parentLineage.rootJobID
            self.rootResultID = parentLineage.rootResultID
        } else {
            self.rootJobID = parentJobID
            self.rootResultID = parentResultID
        }
        self.parentJobID = parentJobID
        self.parentResultID = parentResultID
        self.relationRawValue = relation.rawValue
        self.lineageDepth = (parentLineage?.lineageDepth ?? 0) + 1
    }

    /// 直接构造（解码或 root 滚动用）。
    init(
        schemaVersion: Int = 1,
        rootJobID: String,
        rootResultID: String,
        parentJobID: String,
        parentResultID: String,
        relationRawValue: String,
        lineageDepth: Int
    ) {
        self.schemaVersion = schemaVersion
        self.rootJobID = rootJobID
        self.rootResultID = rootResultID
        self.parentJobID = parentJobID
        self.parentResultID = parentResultID
        self.relationRawValue = relationRawValue
        self.lineageDepth = lineageDepth
    }

    /// lineage 环检测：child 自身的 jobID 不得出现在 parent/root 上。
    func formsCycle(withChildJobID childJobID: String) -> Bool {
        childJobID == parentJobID || childJobID == rootJobID
    }

    /// 是否达到深度上限，应滚动为新 root。
    var needsRollingRoot: Bool {
        lineageDepth >= HoloAgentLineageLimit.maxDepth
    }
}
