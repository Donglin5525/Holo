//
//  HealthInsightContext.swift
//  Holo
//
//  健康洞察上下文模型
//  用于将 HealthKit 数据引入洞察生成链路
//

import Foundation

/// 健康数据可用性
enum HealthDataAvailability: Equatable {
    case fullyAvailable
    case partiallyAvailable(availableTypes: [String], missingTypes: [String])
    case notAvailable(reason: String)
}

// MARK: - 手写 Codable（带标签关联值无法自动合成）

extension HealthDataAvailability: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case availableTypes
        case missingTypes
        case reason
    }

    private enum Kind: String, Codable {
        case fullyAvailable
        case partiallyAvailable
        case notAvailable
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fullyAvailable:
            try container.encode(Kind.fullyAvailable, forKey: .kind)
        case .partiallyAvailable(let available, let missing):
            try container.encode(Kind.partiallyAvailable, forKey: .kind)
            try container.encode(available, forKey: .availableTypes)
            try container.encode(missing, forKey: .missingTypes)
        case .notAvailable(let reason):
            try container.encode(Kind.notAvailable, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .fullyAvailable:
            self = .fullyAvailable
        case .partiallyAvailable:
            let available = try container.decodeIfPresent([String].self, forKey: .availableTypes) ?? []
            let missing = try container.decodeIfPresent([String].self, forKey: .missingTypes) ?? []
            self = .partiallyAvailable(availableTypes: available, missingTypes: missing)
        case .notAvailable:
            let reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? "未授权"
            self = .notAvailable(reason: reason)
        }
    }
}

/// 健康信号
struct HealthSignal: Codable, Equatable {
    let type: String        // sleepShort / stepLow / standLow / workoutRecovery
    let severity: String    // info / warning
    let title: String
    let evidence: [String]
}

/// 健康洞察上下文
struct HealthInsightContext: Codable, Equatable {
    let sleepDurationHours: Double?
    let stepCount: Int?
    let standHours: Int?
    let workoutMinutes: Int?
    let dataAvailability: HealthDataAvailability
    let signals: [HealthSignal]

    // —— 2026-09-24 富字段扩充（对齐深度分析健康域）：var+默认值，旧 JSON 可继续解码 ——
    // 环比素材（回顾模板「趋势分析」段消费，与 previousPeriodExpense 同一模式）
    var previousPeriodSleepHours: Double? = nil
    var previousPeriodStepCount: Int? = nil
    // 活动与运动
    var activeMinutesPerDay: Double? = nil
    var activeEnergyKcalPerDay: Double? = nil
    var distanceKmPerDay: Double? = nil
    var workoutSessionCount: Int? = nil
    var topWorkoutTypes: [String]? = nil
    // 睡眠质量（无 Apple Watch 分期数据时为 nil，不得当 0 解读）
    var sleepEfficiencyPercent: Double? = nil
    var deepSleepHoursPerDay: Double? = nil
    var remSleepHoursPerDay: Double? = nil
    /// 平均就寝时刻（一天内分钟，23:00=1380；凌晨入睡折算为次日，均值还原到 0-1439）
    var bedtimeMinuteOfDay: Int? = nil
    var wakeMinuteOfDay: Int? = nil
    /// 本周期内至少有一项健康数据的天数（诚实口径：均值的天数分母背景）
    var recordedDayCount: Int? = nil
}
