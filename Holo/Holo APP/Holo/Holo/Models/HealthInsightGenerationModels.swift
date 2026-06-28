//
//  HealthInsightGenerationModels.swift
//  Holo
//
//  健康洞察 LLM 生成的数据模型。
//  分两类：
//  1. 展示/缓存模型（GeneratedHealthInsightSnapshot 等）：严格结构，供 UI / Verifier / Cache 使用；
//  2. LLM 原始响应模型（HealthInsightLLMResponse 等）：宽容解析，供 HealthInsightResponseParser 转换。
//     后端返回的 JSON 不含 kind（由 coreInsight / lifestyleLoops 位置决定），字段全部宽容，
//     由 parser 决定取舍，避免 LLM 漏字段或返回未知枚举值导致整体解析失败。
//

import Foundation

// MARK: - 枚举

/// 洞察种类：核心洞察 / 生活闭环。
enum HealthInsightKind: String, Codable, Sendable, CaseIterable {
    case core
    case lifestyleLoop
}

/// 洞察所属域。严格枚举，LLM 传未知值时由 parser 回退 `.mixed`。
enum HealthInsightDomain: String, Codable, Sendable, CaseIterable {
    case health
    case task
    case habit
    case finance
    case thought
    case mixed
}

/// 洞察生成状态，驱动 UI 展示「生成中 / 今日已更新 / 数据不足 / 使用本地兜底」等文案。
enum HealthInsightGenerationStatus: String, Codable, Sendable, CaseIterable {
    /// 正在生成中
    case generating
    /// 今日新生成成功
    case fresh
    /// 命中今日缓存，未重新生成
    case cached
    /// 数据不足，无法生成
    case insufficientData
    /// 生成失败，使用本地规则兜底
    case fallback
    /// 功能未开启（未授权 HealthKit / feature flag 关闭）
    case disabled
}

// MARK: - 展示 / 缓存模型

/// 洞察覆盖的时间窗口。
struct HealthInsightPeriod: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
    var days: Int
}

/// 单条证据（脱敏摘要 + 同源 id，id 遵循 `<domain>-<subKind>-<yyyyMMdd>` 规范）。
struct HealthInsightEvidence: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var domain: HealthInsightDomain
    var occurredAt: Date?
    var title: String
    var detail: String
    var metricKey: String?
    var metricValue: Double?
    var unit: String?
}

/// 一条 LLM 生成的洞察（核心或生活闭环）。
struct GeneratedHealthInsight: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: HealthInsightKind
    var domain: HealthInsightDomain
    var title: String
    var summary: String
    var suggestedAction: String?
    var confidence: Double
    var evidenceIds: [String]
    var caveat: String?
}

/// 健康洞察完整快照：UI 渲染 + 缓存的顶层结构。
struct GeneratedHealthInsightSnapshot: Codable, Equatable, Sendable {
    var generatedAt: Date
    var period: HealthInsightPeriod
    var status: HealthInsightGenerationStatus
    var coreInsight: GeneratedHealthInsight?
    var lifestyleLoops: [GeneratedHealthInsight]
    var evidence: [HealthInsightEvidence]
    var fallbackReason: String?
}

// MARK: - LLM 原始响应模型（宽容解析）

/// 后端返回的原始结构（对应方案 4.2 JSON）。
struct HealthInsightLLMResponse: Codable, Equatable, Sendable {
    var coreInsight: HealthInsightLLMItem?
    var lifestyleLoops: [HealthInsightLLMItem]?
}

/// LLM 返回的单条洞察原始项，字段全部可选，由 parser 决定取舍。
struct HealthInsightLLMItem: Codable, Equatable, Sendable {
    var id: String?
    var domain: String?
    var title: String?
    var summary: String?
    var suggestedAction: String?
    var confidence: Double?
    var evidenceIds: [String]?
    var caveat: String?
}
