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
}
