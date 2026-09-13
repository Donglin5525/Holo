//
//  HoloMatterModels.swift
//  Holo
//
//  Matter「进行中的事」——类型化契约层（投影 / Proposal / 激活契约 / 会话上下文）
//
//  枚举词汇见 HoloMatterVocabulary.swift（app 与 widget 共享）。
//  投影（summary/attention/nextAction）不是事实，是带 sourceRevision 的可重建投影。
//  参考：docs/_common/plans/2026-09-11-Holo-Matter进行中的事完整实施方案.md §9
//

import Foundation

// MARK: - 投影（可重建、带来源修订）

/// 证据引用：指向真实业务对象的最小定位，可回源。
nonisolated struct HoloMatterEvidenceRef: Codable, Equatable, Sendable {
    var entityType: String
    var entityID: String
    var excerpt: String?
    var sourceRevision: String?

    init(entityType: String, entityID: String, excerpt: String? = nil, sourceRevision: String? = nil) {
        self.entityType = entityType
        self.entityID = entityID
        self.excerpt = excerpt
        self.sourceRevision = sourceRevision
    }
}

/// Next Action 最多一个；指向已确认 Open Loop、已存在 Task 或明确标记为建议的候选。
nonisolated struct HoloMatterNextAction: Codable, Equatable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case linkedTask
        case openLoopAction
        case suggestion
    }

    var kind: Kind
    var entityID: String?
    var title: String
    var reason: String
    var targetDate: Date?
    var evidenceRefs: [HoloMatterEvidenceRef]

    init(
        kind: Kind,
        entityID: String? = nil,
        title: String,
        reason: String,
        targetDate: Date? = nil,
        evidenceRefs: [HoloMatterEvidenceRef] = []
    ) {
        self.kind = kind
        self.entityID = entityID
        self.title = title
        self.reason = reason
        self.targetDate = targetDate
        self.evidenceRefs = evidenceRefs
    }
}

/// 投影 V1：确定性状态 + AI 摘要。`sourceMatterRevision != matter.revision` 即 stale，UI 先用确定性数据。
nonisolated struct HoloMatterProjectionV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var matterID: UUID
    var sourceMatterRevision: Int64
    var summary: String
    var attention: HoloMatterAttention
    var attentionReason: String?
    var nextAction: HoloMatterNextAction?
    var evidenceRefs: [HoloMatterEvidenceRef]
    var generatedAt: Date
    var staleReason: String?

    init(
        matterID: UUID,
        sourceMatterRevision: Int64,
        summary: String,
        attention: HoloMatterAttention,
        attentionReason: String? = nil,
        nextAction: HoloMatterNextAction? = nil,
        evidenceRefs: [HoloMatterEvidenceRef] = [],
        generatedAt: Date,
        staleReason: String? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.matterID = matterID
        self.sourceMatterRevision = sourceMatterRevision
        self.summary = summary
        self.attention = attention
        self.attentionReason = attentionReason
        self.nextAction = nextAction
        self.evidenceRefs = evidenceRefs
        self.generatedAt = generatedAt
        self.staleReason = staleReason
    }

    /// 损坏/未知版本的投影一律丢弃重建，不启动崩溃。
    static func decode(from json: String?, matterRevision: Int64) -> HoloMatterProjectionV1? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let projection = try? JSONDecoder.holoMatter.decode(HoloMatterProjectionV1.self, from: data) else {
            return nil
        }
        guard projection.schemaVersion == Self.schemaVersion else { return nil }
        return projection
    }

    func encodeJSON() -> String? {
        guard let data = try? JSONEncoder.holoMatter.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 投影是否已过期（来源 Matter 又发生了 canonical 变更）。
    func isStale(currentRevision: Int64) -> Bool {
        return sourceMatterRevision != currentRevision
    }
}

// MARK: - Mutation Proposal（模型只能提议）

/// Open Loop 草稿：模型提议新增的问题，落库一律 suggested。
nonisolated struct HoloMatterOpenLoopDraft: Codable, Equatable, Sendable {
    var logicalKey: String
    var title: String
    var priority: HoloMatterOpenLoopPriority
    var targetDate: Date?
    var reason: String?

    init(
        logicalKey: String,
        title: String,
        priority: HoloMatterOpenLoopPriority = .normal,
        targetDate: Date? = nil,
        reason: String? = nil
    ) {
        self.logicalKey = logicalKey
        self.title = title
        self.priority = priority
        self.targetDate = targetDate
        self.reason = reason
    }
}

nonisolated struct HoloMatterLinkDraft: Codable, Equatable, Sendable {
    var entityType: HoloMatterLinkEntityType
    var entityID: String
    var role: HoloMatterLinkRole
    var reason: String?

    init(entityType: HoloMatterLinkEntityType, entityID: String, role: HoloMatterLinkRole, reason: String? = nil) {
        self.entityType = entityType
        self.entityID = entityID
        self.role = role
        self.reason = reason
    }
}

/// 歧义：validator 判定无法唯一定位时给出，禁止按置信度硬执行。
nonisolated struct HoloMatterAmbiguity: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var question: String
    /// 候选项标题（如「东京住宿」「京都住宿」），UI 直接展示。
    var options: [HoloMatterAmbiguityOption]

    init(id: String, question: String, options: [HoloMatterAmbiguityOption] = []) {
        self.id = id
        self.question = question
        self.options = options
    }
}

nonisolated struct HoloMatterAmbiguityOption: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var openLoopID: UUID?

    init(id: String, title: String, openLoopID: UUID? = nil) {
        self.id = id
        self.title = title
        self.openLoopID = openLoopID
    }
}

nonisolated enum HoloMatterMutation: Codable, Equatable, Sendable {
    /// 新增 AI 建议的问题（落库即 suggested，永不直接 confirmed）。
    case addSuggestedOpenLoop(HoloMatterOpenLoopDraft)
    /// 把建议升为 confirmed——需要一次用户确认，模型不可触发。
    case confirmOpenLoop(openLoopID: UUID)
    /// 更新 Open Loop 状态（仅限 Matter 内明确、唯一、低风险的语义）。
    case setOpenLoopState(openLoopID: UUID, state: HoloMatterOpenLoopState)
    /// 提议关联外部内容（需要用户确认）。
    case proposeLink(HoloMatterLinkDraft)
    /// 刷新投影。
    case refreshProjection(HoloMatterProjectionV1)
}

/// 模型输出的 typed proposal。validator 拒绝一切含越权 mutation / 未知 ID / 过期 revision 的 proposal。
nonisolated struct HoloMatterMutationProposal: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var proposalID: String
    var matterID: UUID
    var baseMatterRevision: Int64
    var sourceRefs: [HoloMatterEvidenceRef]
    var mutations: [HoloMatterMutation]
    var ambiguities: [HoloMatterAmbiguity]
    var summarySuggestion: String?
    var nextActionSuggestion: HoloMatterNextAction?

    init(
        proposalID: String,
        matterID: UUID,
        baseMatterRevision: Int64,
        sourceRefs: [HoloMatterEvidenceRef] = [],
        mutations: [HoloMatterMutation] = [],
        ambiguities: [HoloMatterAmbiguity] = [],
        summarySuggestion: String? = nil,
        nextActionSuggestion: HoloMatterNextAction? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.proposalID = proposalID
        self.matterID = matterID
        self.baseMatterRevision = baseMatterRevision
        self.sourceRefs = sourceRefs
        self.mutations = mutations
        self.ambiguities = ambiguities
        self.summarySuggestion = summarySuggestion
        self.nextActionSuggestion = nextActionSuggestion
    }
}

// MARK: - 激活契约

nonisolated struct HoloMatterActivationRequest: Sendable {
    var draft: HoloContextPlanDraft
    var contextPlanMessageID: UUID
    var userMessageID: UUID?
    var confirmedTitle: String
    var confirmedTargetDate: Date?
    /// 命中已有 Matter 时由用户选择「更新到已有」，携带其 ID。
    var existingMatterID: UUID?

    init(
        draft: HoloContextPlanDraft,
        contextPlanMessageID: UUID,
        userMessageID: UUID? = nil,
        confirmedTitle: String,
        confirmedTargetDate: Date? = nil,
        existingMatterID: UUID? = nil
    ) {
        self.draft = draft
        self.contextPlanMessageID = contextPlanMessageID
        self.userMessageID = userMessageID
        self.confirmedTitle = confirmedTitle
        self.confirmedTargetDate = confirmedTargetDate
        self.existingMatterID = existingMatterID
    }
}

nonisolated struct HoloMatterActivationReceipt: Equatable, Sendable {
    var matterID: UUID
    var created: Bool
    var linkedEntityIDs: [String]
    var suggestedOpenLoopIDs: [UUID]
    var eventID: UUID
}

// MARK: - 会话上下文

nonisolated enum HoloMatterConversationEntrySource: String, Codable, Sendable {
    case matterDetail
    case homeFocusCard
    case listQuickAction
}

/// Matter-scoped Chat 的类型化上下文。走显式 matterID，禁止靠标题关键词猜。
nonisolated struct HoloMatterConversationContext: Equatable, Sendable {
    var matterID: UUID
    var source: HoloMatterConversationEntrySource

    init(matterID: UUID, source: HoloMatterConversationEntrySource) {
        self.matterID = matterID
        self.source = source
    }
}
