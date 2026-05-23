//
//  InsightPreferenceProfile.swift
//  Holo
//
//  洞察偏好画像模型
//  独立于 HoloProfile，存储 AI 洞察系统的结构化偏好
//

import Foundation

// MARK: - Module Key

/// 洞察模块标识（比 InsightModule 更广，覆盖展示层类型）
enum InsightModuleKey: String, Codable {
    case finance, habit, task, thought, health
    case crossDomain, overview, anomaly, milestone
}

// MARK: - Preference Types

/// 模块偏好权重
struct InsightModulePreference: Codable, Equatable {
    let module: InsightModuleKey
    var weight: Double          // 默认 1.0，范围 0.0-2.0
    var evidenceCount: Int      // 支撑此权重的反馈次数
    var isStable: Bool          // true = 已升级为稳定偏好，不过期

    static func defaultValue(for module: InsightModuleKey) -> InsightModulePreference {
        InsightModulePreference(module: module, weight: 1.0, evidenceCount: 0, isStable: false)
    }
}

/// 模式偏好（降权用）
struct InsightPatternPreference: Codable, Equatable {
    let patternType: String
    var penalty: Double         // 默认 0.0，范围 0.0-1.0
    var reason: String?
    var evidenceCount: Int
    var isStable: Bool
}

/// 语气偏好
enum InsightTonePreference: String, Codable, CaseIterable {
    case balanced
    case direct
    case gentle
    case dataFirst
    case fewerSuggestions
}

/// 建议类型偏好
struct InsightSuggestionPreference: Codable, Equatable {
    let suggestionType: InsightActionType
    var weight: Double
    var evidenceCount: Int
    var isStable: Bool
}

/// 循环主题
struct InsightRecurringTheme: Codable, Equatable {
    let theme: String
    var frequency: Int
    var lastSeenAt: Date
}

// MARK: - Action Types (Phase 6 前置定义)

/// 行动类型
enum InsightActionType: String, Codable {
    case createTask
    case adjustHabit
    case budgetReminder
    case reflectionQuestion
    case scheduleCheckIn
    case noAction
}

// MARK: - Profile

/// 洞察偏好画像
struct InsightPreferenceProfile: Codable, Equatable {
    var schemaVersion: Int
    var moduleWeights: [InsightModulePreference]
    var dislikedPatterns: [InsightPatternPreference]
    var preferredTone: InsightTonePreference
    var usefulSuggestionTypes: [InsightSuggestionPreference]
    var recurringThemes: [InsightRecurringTheme]
    var lastDataActivityDate: Date?
    var updatedAt: Date

    static func `default`() -> InsightPreferenceProfile {
        InsightPreferenceProfile(
            schemaVersion: 1,
            moduleWeights: [],
            dislikedPatterns: [],
            preferredTone: .balanced,
            usefulSuggestionTypes: [],
            recurringThemes: [],
            lastDataActivityDate: nil,
            updatedAt: Date()
        )
    }

    // MARK: - Codable (decodeIfPresent + 默认值)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        moduleWeights = try container.decodeIfPresent([InsightModulePreference].self, forKey: .moduleWeights) ?? []
        dislikedPatterns = try container.decodeIfPresent([InsightPatternPreference].self, forKey: .dislikedPatterns) ?? []
        preferredTone = try container.decodeIfPresent(InsightTonePreference.self, forKey: .preferredTone) ?? .balanced
        usefulSuggestionTypes = try container.decodeIfPresent([InsightSuggestionPreference].self, forKey: .usefulSuggestionTypes) ?? []
        recurringThemes = try container.decodeIfPresent([InsightRecurringTheme].self, forKey: .recurringThemes) ?? []
        lastDataActivityDate = try container.decodeIfPresent(Date.self, forKey: .lastDataActivityDate)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    init(
        schemaVersion: Int = 1,
        moduleWeights: [InsightModulePreference] = [],
        dislikedPatterns: [InsightPatternPreference] = [],
        preferredTone: InsightTonePreference = .balanced,
        usefulSuggestionTypes: [InsightSuggestionPreference] = [],
        recurringThemes: [InsightRecurringTheme] = [],
        lastDataActivityDate: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.moduleWeights = moduleWeights
        self.dislikedPatterns = dislikedPatterns
        self.preferredTone = preferredTone
        self.usefulSuggestionTypes = usefulSuggestionTypes
        self.recurringThemes = recurringThemes
        self.lastDataActivityDate = lastDataActivityDate
        self.updatedAt = updatedAt
    }
}
