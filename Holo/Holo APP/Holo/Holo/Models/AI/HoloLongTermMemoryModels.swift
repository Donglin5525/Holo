//
//  HoloLongTermMemoryModels.swift
//  Holo
//
//  长期记忆模型：候选、确认、证据
//

import Foundation

// MARK: - 语义类型（按 AI 使用场景分类）

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
    /// 同一记忆主题跨洞察周期的稳定身份键
    var subjectKey: String
    var title: String
    var confidence: HoloMemoryConfidence
    var confirmationState: HoloMemoryConfirmationState
    var sensitivity: HoloMemorySensitivity
    var evidence: [HoloLongTermMemoryEvidence]
    var createdAt: Date
    var updatedAt: Date
    var expiresAt: Date?

    /// 新格式唯一类型；旧格式由迁移 DTO 解码后直接删除
    var semanticType: HoloMemorySemanticType
    /// 用户可审核的事实摘要
    var displaySummary: String
    /// 注入 AI prompt 的上下文摘要
    var aiUseSummary: String
    /// 允许召回的场景
    var useScopes: [HoloMemoryUseScope]
    /// 召回时必须遵守的误用边界
    var prohibitedInferences: [String]
}

// MARK: - 证据

struct HoloLongTermMemoryEvidence: Codable, Equatable, Identifiable {
    var id: String
    var source: HoloMemorySource
    var sourceID: String?
    var excerpt: String
    var observedAt: Date
}

enum HoloLongTermMemoryEvidenceMerger {
    /// 相同业务证据跨洞察周期只保留一份，优先使用 sourceID，否则按来源、文本和自然日去重。
    static func merge(
        _ existing: [HoloLongTermMemoryEvidence],
        _ incoming: [HoloLongTermMemoryEvidence]
    ) -> [HoloLongTermMemoryEvidence] {
        var merged: [HoloLongTermMemoryEvidence] = []
        var keys = Set<String>()
        for evidence in existing + incoming {
            let key: String
            if let sourceID = evidence.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sourceID.isEmpty {
                key = "\(evidence.source.rawValue)|id|\(sourceID)"
            } else {
                let excerpt = evidence.excerpt
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let day = Int(evidence.observedAt.timeIntervalSince1970 / 86_400)
                key = "\(evidence.source.rawValue)|text|\(excerpt)|\(day)"
            }
            if keys.insert(key).inserted {
                merged.append(evidence)
            }
        }
        return merged.sorted { $0.observedAt < $1.observedAt }
    }
}

/// 记忆身份只由语义类型、业务域和稳定主题键决定，不能使用每份报告内重复的 card.id。
enum HoloSemanticMemoryIdentity {
    static func normalizeSubjectKey(_ rawValue: String) -> String? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "_")
        guard (2...80).contains(normalized.count) else { return nil }
        return normalized
    }

    static func makeID(
        semanticType: HoloMemorySemanticType,
        domain: String,
        subjectKey: String
    ) -> String {
        let identity = "\(semanticType.rawValue)|\(domain.lowercased())|\(subjectKey)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "memory-v2-" + String(hash, radix: 16)
    }
}

// MARK: - 旧 JSON 一次性迁移

/// 只用于读取 2026-07-14 之前的宽松 JSON；禁止作为运行时领域模型使用。
struct HoloLongTermMemoryMigrationRecord: Codable {
    var id: String
    var subjectKey: String?
    var title: String
    var confidence: HoloMemoryConfidence
    var confirmationState: HoloMemoryConfirmationState
    var sensitivity: HoloMemorySensitivity
    var evidence: [HoloLongTermMemoryEvidence]
    var createdAt: Date
    var updatedAt: Date
    var expiresAt: Date?
    var semanticType: HoloMemorySemanticType?
    var displaySummary: String?
    var aiUseSummary: String?
    var useScopes: [HoloMemoryUseScope]?
    var prohibitedInferences: [String]?

    /// 兼容旧 JSON 中仍存在的字段，解码后不进入 V2 模型。
    var type: String?
    var summary: String?
}

struct HoloLongTermMemoryMigrationResult {
    var memories: [HoloLongTermMemory]
    var removedLegacyCount: Int
    var removedInvalidCount: Int
}

enum HoloLongTermMemoryMigration {
    static func decodeAndFilter(_ data: Data) throws -> HoloLongTermMemoryMigrationResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([HoloLongTermMemoryMigrationRecord].self, from: data)

        var memories: [HoloLongTermMemory] = []
        var removedLegacyCount = 0
        var removedInvalidCount = 0

        for record in records {
            guard let semanticType = record.semanticType else {
                removedLegacyCount += 1
                continue
            }
            guard let subjectKey = record.subjectKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !subjectKey.isEmpty,
                  let displaySummary = record.displaySummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !displaySummary.isEmpty,
                  let aiUseSummary = record.aiUseSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !aiUseSummary.isEmpty,
                  let useScopes = record.useScopes,
                  !useScopes.isEmpty,
                  let prohibitedInferences = record.prohibitedInferences,
                  !record.evidence.isEmpty else {
                removedInvalidCount += 1
                continue
            }

            memories.append(HoloLongTermMemory(
                id: record.id,
                subjectKey: subjectKey,
                title: record.title,
                confidence: record.confidence,
                confirmationState: record.confirmationState,
                sensitivity: record.sensitivity,
                evidence: record.evidence,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                expiresAt: record.expiresAt,
                semanticType: semanticType,
                displaySummary: displaySummary,
                aiUseSummary: aiUseSummary,
                useScopes: useScopes,
                prohibitedInferences: prohibitedInferences
            ))
        }

        return HoloLongTermMemoryMigrationResult(
            memories: memories,
            removedLegacyCount: removedLegacyCount,
            removedInvalidCount: removedInvalidCount
        )
    }
}
