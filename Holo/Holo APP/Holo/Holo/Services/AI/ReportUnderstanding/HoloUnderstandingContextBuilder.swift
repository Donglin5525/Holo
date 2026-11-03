//
//  HoloUnderstandingContextBuilder.swift
//  Holo
//
//  统一任务相关摘要构造层（README §7.1/ADR-08）：财务 S2 T03 的
//  PersonalSituationBrief 由本类型唯一实现——两方案共用同一契约与单一注入入口。
//  - 底层复用 HoloMemoryQueryService（active 过滤+相关性+预算），不另建检索；
//  - 只输出事实型条目（observedFact/recurringPattern/phaseShift），
//    hypothesis/association 不直接送规划与分析（§7.2 消费边界）；
//  - 空背景 = 正常分析；关闭记忆辅助回答时输出空（R24）。
//

import Foundation
import OSLog

nonisolated struct HoloPersonalSituationItem: Codable, Equatable, Sendable {
    var memoryID: String
    var versionID: String
    var displayText: String
    var conditions: [String]
    /// 自然语言时间窗（如「2026-09 至 2026-10」）；nil=长期。
    var timeWindowLabel: String?
    var allowedUse: String
    var caveat: String?
}

nonisolated struct HoloPersonalSituationBrief: Codable, Equatable, Sendable {
    /// 上限对齐 HoloMemoryQueryBudgetPolicy.defaultMaximumRecords（8 条）。
    static let itemLimit = 8
    static let empty = HoloPersonalSituationBrief(items: [])

    var items: [HoloPersonalSituationItem]

    var isEmpty: Bool { items.isEmpty }
}

nonisolated enum HoloUnderstandingContextBuilder {
    private static let logger = Logger(
        subsystem: "com.holo.app",
        category: "UnderstandingContextBuilder"
    )

    /// 事实型命题才可进入背景投影（§5.3 信息准入）。
    private static let factClaimKinds: Set<HoloMemoryClaimKind> = [
        .observedFact, .recurringPattern, .phaseShift, .lifeEvent,
    ]

    /// 构造当前问题的个人情境背景（PersonalSituationBrief）。
    /// - Parameters:
    ///   - question: 当前问题（空 = 通用背景，用于分析快照）。
    static func brief(
        question: String = "",
        now: Date = Date()
    ) async -> HoloPersonalSituationBrief {
        guard HoloAIFeatureFlags.reportUnderstandingAnsweringEnabled,
              HoloAIFeatureFlags.memorySummaryInjectionEnabled else {
            return .empty
        }
        guard let service = try? await HoloMemoryQueryService.live() else { return .empty }
        guard let context = try? await service.query(
            question: question,
            consumer: .agent,
            now: now
        ) else { return .empty }

        let items = context.records
            .filter { factClaimKinds.contains($0.claimKind) }
            .prefix(HoloPersonalSituationBrief.itemLimit)
            .map { record in
                HoloPersonalSituationItem(
                    memoryID: record.id,
                    versionID: record.versionID,
                    displayText: record.aiUseSummary,
                    // 信封 V1 的 statement 自带必要条件（「可独立理解的克制命题」）
                    conditions: record.personalContext?.v1.map { [$0.statement] } ?? [],
                    timeWindowLabel: Self.timeWindowLabel(record),
                    allowedUse: Self.allowedUse(record),
                    caveat: record.prohibitedInferences.first
                )
            }
        // 使用统计：本轮被选入背景的记忆记一次使用（专用通道，不动版本链）
        if !items.isEmpty {
            let ids = items.map(\.memoryID)
            if let repository = try? await HoloMemoryRuntime.shared.repository() {
                try? await repository.recordUsage(ids: ids, now: now)
            }
        }
        let brief = HoloPersonalSituationBrief(items: Array(items))
        logger.info("PersonalSituationBrief 构造：\(brief.items.count, privacy: .public) 条")
        return brief
    }

    /// 长期命题不带窗；阶段性命题带 validFrom/validTo 月粒度窗。
    private static func timeWindowLabel(_ record: HoloMemoryRecord) -> String? {
        guard record.persistenceClass != .durable,
              record.persistenceClass != .permanentFact else { return nil }
        guard let from = record.validFrom else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let start = formatter.string(from: from)
        if let to = record.validTo {
            return "\(start) 至 \(formatter.string(from: to))"
        }
        return "\(start) 起"
    }

    private static func allowedUse(_ record: HoloMemoryRecord) -> String {
        switch record.claimKind {
        case .phaseShift:
            return "阶段背景：仅作时间安排与解释参考，不外推为固定人格"
        case .recurringPattern:
            return "模式背景：保留条件与反例，不得当永久结论"
        default:
            return "事实背景"
        }
    }
}
