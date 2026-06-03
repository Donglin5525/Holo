//
//  HoloObservationPackageBuilder.swift
//  Holo
//
//  观察包构建器：组装各模块信号为结构化 JSON，支持 token 裁剪
//

import Foundation

// MARK: - Package Limits

struct HoloObservationPackageLimits {
    static let maxTotalEstimatedTokens = 12_000
    static let habitSignalsMaxCount = 20
    static let goalSignalsMaxCount = 10
    static let existingEpisodicMemoriesMaxCount = 20
    static let existingLongTermMemoriesMaxCount = 10
    static let suppressionRulesMaxCount = 20
}

// MARK: - Package Models

struct HoloObservationPackage: Codable {
    var runID: String
    var period: ObservationPeriod
    var habitSignals: [HoloMemorySignal]
    var goalSignals: [HoloMemorySignal]
    var existingEpisodicMemories: [HoloEpisodicMemorySummary]
    var existingLongTermMemories: [HoloLongTermMemorySummary]
    var memoryFeedbackHistory: [HoloMemoryFeedbackEntry]
    var suppressionRules: [HoloMemorySuppressionRule]
    var estimatedTokens: Int
    var truncated: Bool
}

struct ObservationPeriod: Codable {
    var start: String  // ISO8601
    var end: String
    var window: String  // "fourteenDays"
}

struct HoloEpisodicMemorySummary: Codable {
    var id: String
    var title: String
    var summary: String
    var state: HoloEpisodicMemoryState
    var hitCount: Int
    var lastHitAt: String?
}

struct HoloLongTermMemorySummary: Codable {
    var id: String
    var title: String
    var summary: String
}

struct HoloMemoryFeedbackEntry: Codable {
    var memoryID: String
    var action: String  // "rejected" / "deleted" / "edited"
    var originalSummary: String?
    var editedSummary: String?
    var timestamp: String
}

// MARK: - Builder

struct HoloObservationPackageBuilder {

    /// MVP 只支持 Habit + Goal 信号
    static func buildPackage(
        habitSignals: [HoloMemorySignal],
        goalSignals: [HoloMemorySignal],
        existingEpisodicMemories: [HoloEpisodicMemory],
        existingLongTermMemories: [HoloLongTermMemory],
        suppressionRules: [HoloMemorySuppressionRule],
        memoryFeedbackHistory: [HoloMemoryFeedbackEntry] = []
    ) -> HoloObservationPackage {
        // 生成 runID
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let runID = "obs-\(formatter.string(from: Date()))"

        // 时间窗口
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -14, to: now)!
        let isoFormatter = ISO8601DateFormatter()
        let period = ObservationPeriod(
            start: isoFormatter.string(from: start),
            end: isoFormatter.string(from: now),
            window: "fourteenDays"
        )

        // 按限制截断信号
        let truncatedHabitSignals = Array(habitSignals
            .sorted(by: { $0.confidence > $1.confidence })
            .prefix(HoloObservationPackageLimits.habitSignalsMaxCount))
        let truncatedGoalSignals = Array(goalSignals
            .sorted(by: { $0.confidence > $1.confidence })
            .prefix(HoloObservationPackageLimits.goalSignalsMaxCount))

        // 既有记忆摘要（只传摘要，不传完整 evidence）
        let episodicSummaries = existingEpisodicMemories
            .filter { $0.state == .active || $0.state == .suggested }
            .sorted { ($0.lastHitAt ?? .distantPast) > ($1.lastHitAt ?? .distantPast) }
            .prefix(HoloObservationPackageLimits.existingEpisodicMemoriesMaxCount)
            .map { mem -> HoloEpisodicMemorySummary in
                HoloEpisodicMemorySummary(
                    id: mem.id,
                    title: mem.title,
                    summary: mem.summary,
                    state: mem.state,
                    hitCount: mem.hitCount,
                    lastHitAt: mem.lastHitAt.map { isoFormatter.string(from: $0) }
                )
            }

        let ltmSummaries = existingLongTermMemories
            .filter { $0.confirmationState == .confirmed || $0.confirmationState == .silentlyAccepted }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(HoloObservationPackageLimits.existingLongTermMemoriesMaxCount)
            .map { mem -> HoloLongTermMemorySummary in
                HoloLongTermMemorySummary(
                    id: mem.id,
                    title: mem.title,
                    summary: mem.summary
                )
            }

        let truncatedRules = Array(suppressionRules
            .prefix(HoloObservationPackageLimits.suppressionRulesMaxCount))

        // 组装 package
        var package = HoloObservationPackage(
            runID: runID,
            period: period,
            habitSignals: truncatedHabitSignals,
            goalSignals: truncatedGoalSignals,
            existingEpisodicMemories: Array(episodicSummaries),
            existingLongTermMemories: Array(ltmSummaries),
            memoryFeedbackHistory: memoryFeedbackHistory,
            suppressionRules: truncatedRules,
            estimatedTokens: 0,
            truncated: false
        )

        // Token 估算与裁剪
        package.estimatedTokens = estimateTokens(package)
        package = trimToTokenBudget(package)

        return package
    }

    // MARK: - Token Estimation

    private static func estimateTokens(_ package: HoloObservationPackage) -> Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(package),
              let json = String(data: data, encoding: .utf8) else {
            return 0
        }
        // CJK 字符 × 1.5，其他字符 × 0.25
        var tokens = 0
        for scalar in json.unicodeScalars {
            let value = scalar.value
            if (0x4E00...0x9FFF).contains(value) ||     // CJK 统一汉字
               (0x3000...0x303F).contains(value) ||      // CJK 标点
               (0x3040...0x309F).contains(value) ||      // 平假名
               (0x30A0...0x30FF).contains(value) {       // 片假名
                tokens += 2  // CJK 约 1.5-2 token/字
            } else {
                tokens += 1  // ASCII 约 0.25 token/char，但按保守估算
            }
        }
        return tokens
    }

    private static func trimToTokenBudget(_ package: HoloObservationPackage) -> HoloObservationPackage {
        var result = package
        let budget = HoloObservationPackageLimits.maxTotalEstimatedTokens

        guard result.estimatedTokens > budget else { return result }

        result.truncated = true

        // 按优先级裁剪：反馈历史 → 既有长期记忆 → 既有情景记忆 → 目标信号
        // 反馈历史最低优先级
        if result.estimatedTokens > budget {
            result.memoryFeedbackHistory = []
            result.estimatedTokens = estimateTokens(result)
        }

        // 既有长期记忆
        if result.estimatedTokens > budget {
            result.existingLongTermMemories = []
            result.estimatedTokens = estimateTokens(result)
        }

        // 既有情景记忆按 lastHitAt 降序保留
        if result.estimatedTokens > budget {
            let keep = max(result.existingEpisodicMemories.count / 2, 5)
            result.existingEpisodicMemories = Array(result.existingEpisodicMemories.prefix(keep))
            result.estimatedTokens = estimateTokens(result)
        }

        // 目标信号按 confidence 降序截断
        if result.estimatedTokens > budget {
            result.goalSignals = Array(result.goalSignals.prefix(5))
            result.estimatedTokens = estimateTokens(result)
        }

        return result
    }
}
