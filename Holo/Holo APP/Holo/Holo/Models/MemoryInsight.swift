//
//  MemoryInsight.swift
//  Holo
//
//  记忆洞察 Core Data 实体
//  AI 生成的周期级洞察结果，作为可复看的个人记忆资产
//

import Foundation
import CoreData

/// 记忆洞察实体
@objc(MemoryInsight)
public class MemoryInsight: NSManagedObject {

    // MARK: - Properties

    @NSManaged public var id: UUID
    @NSManaged public var periodType: String
    @NSManaged public var periodStart: Date
    @NSManaged public var periodEnd: Date
    @NSManaged public var title: String
    @NSManaged public var summary: String
    @NSManaged public var cardsJSON: String
    @NSManaged public var rawResponse: String?
    @NSManaged public var sourceSnapshotHash: String
    @NSManaged public var generatedAt: Date
    @NSManaged public var status: String
    @NSManaged public var errorMessage: String?
    @NSManaged public var promptVersion: Int16
    @NSManaged public var providerName: String?

    // MARK: - Computed Properties

    /// 周期类型枚举
    var insightPeriodType: MemoryInsightPeriodType {
        MemoryInsightPeriodType(rawValue: periodType) ?? .weekly
    }

    /// 状态枚举
    var insightStatus: MemoryInsightStatus {
        MemoryInsightStatus(rawValue: status) ?? .failed
    }

    /// 解析 cardsJSON 为结构化卡片
    var parsedCards: [MemoryInsightCard] {
        guard let data = cardsJSON.data(using: .utf8) else { return [] }
        guard let payload = try? JSONDecoder().decode(MemoryInsightPayload.self, from: data) else { return [] }
        return payload.cards
    }

    /// 解析完整载荷
    var parsedPayload: MemoryInsightPayload? {
        guard let data = cardsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MemoryInsightPayload.self, from: data)
    }

    /// 格式化生成时间
    var formattedGeneratedAt: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: generatedAt)
    }

    /// 格式化周期范围
    var formattedPeriodRange: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let start = formatter.string(from: periodStart)
        let end = formatter.string(from: periodEnd)
        return "\(start) - \(end)"
    }

    /// 是否为本周/本月的洞察
    var isCurrentPeriod: Bool {
        let now = Date()
        return now >= periodStart && now <= periodEnd
    }
}

// MARK: - Concurrency

extension MemoryInsight: @unchecked Sendable {}
