//
//  HoloLongTermMemoryModels.swift
//  Holo
//
//  长期记忆模型：候选、确认、证据
//

import Foundation

// MARK: - 旧类型（按数据来源分类）

enum HoloLongTermMemoryType: String, Codable, Equatable {
    case explicitUserPreference
    case stableFeedbackPreference
    case recurringPattern
    case longTermGoal
    case profileBackedFact
}

// MARK: - 新语义类型（按 AI 使用场景分类）

/// 语义类型：决定记忆如何被 AI 使用
enum HoloMemorySemanticType: String, Codable, Equatable {
    case phaseShift       // 阶段变化
    case stablePattern    // 稳定习惯
    case driftSignal      // 偏离提醒
    case lifeEvent        // 人生节点
    case statMilestone    // 轻量统计收藏
}

/// 使用场景：决定记忆在哪些场景被召回
enum HoloMemoryUseScope: String, Codable, Equatable {
    case coreContext       // 核心上下文，所有场景可用
    case recentInsight     // 近期洞察
    case goalPlanning      // 目标规划
    case retrospective     // 年度回顾/记忆长廊
    case displayOnly       // 仅展示，不参与 AI 召回
}

// MARK: - 枚举辅助

enum HoloMemoryConfidence: String, Codable, Equatable {
    case low
    case medium
    case high
}

enum HoloMemoryConfirmationState: String, Codable, Equatable {
    case candidate
    case silentlyAccepted
    case confirmed
    case rejected
    case archived
}

enum HoloMemorySensitivity: String, Codable, Equatable {
    case normal
    case highImpact
    case sensitive
}

// MARK: - 长期记忆模型

struct HoloLongTermMemory: Codable, Equatable, Identifiable {
    var id: String
    var type: HoloLongTermMemoryType
    var title: String
    var summary: String
    var confidence: HoloMemoryConfidence
    var confirmationState: HoloMemoryConfirmationState
    var sensitivity: HoloMemorySensitivity
    var evidence: [HoloLongTermMemoryEvidence]
    var createdAt: Date
    var updatedAt: Date
    var expiresAt: Date?

    // 新增字段（全部 Optional，兼容旧 JSON）
    // nil = 旧格式数据
    var semanticType: HoloMemorySemanticType?
    /// 用户可审核的事实摘要
    var displaySummary: String?
    /// 注入 AI prompt 的上下文摘要
    var aiUseSummary: String?
    /// 适用场景，nil 时按 fallback 处理
    var useScopes: [HoloMemoryUseScope]?
    /// 误用边界，nil 时视为空
    var prohibitedInferences: [String]?
}

// MARK: - 证据

struct HoloLongTermMemoryEvidence: Codable, Equatable, Identifiable {
    var id: String
    var source: HoloMemorySource
    var sourceID: String?
    var excerpt: String
    var observedAt: Date
}
