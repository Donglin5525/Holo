// 我的积累：确定性的累计口径与里程碑规则，不依赖界面、Core Data 或 AI。
import Foundation

nonisolated enum HoloGrowthMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case finance, thought, habit
    var id: String { rawValue }
    var title: String {
        switch self { case .finance: return "记账天数"; case .thought: return "留下想法"; case .habit: return "习惯打卡" }
    }
    var unit: String { self == .thought ? "条" : "天" }
    var icon: String {
        switch self { case .finance: return "creditcard"; case .thought: return "pencil.line"; case .habit: return "leaf" }
    }
    var thresholds: [Int] { self == .thought ? [1, 10, 50, 100, 500] : [1, 7, 30, 100, 365] }
    var explanation: String {
        switch self {
        case .finance: return "有有效收支记录的日期，同一天只算一次。转账、初始余额和对账调整不计入；归档账户里的有效收支仍然保留。"
        case .thought: return "已经保存的独立想法。编辑和 AI 整理不会重复计数，归档后仍然保留。"
        case .habit: return "至少完成一次正向打卡型习惯的归属日，同一天完成多个习惯也只算一天。沿用习惯的每日结算时间，补签计入对应日期；数值型习惯与坏习惯的发生记录暂不计入。"
        }
    }
    func milestoneTitle(_ threshold: Int) -> String {
        switch self {
        case .finance: return threshold == 1 ? "第一天记账" : "累计记账 \(threshold) 天"
        case .thought: return threshold == 1 ? "留下第一条想法" : "留下第 \(threshold) 条想法"
        case .habit: return threshold == 1 ? "第一天习惯打卡" : "累计打卡 \(threshold) 天"
        }
    }
}

nonisolated struct HoloGrowthFact: Sendable {
    let id: UUID
    /// 来源模块已确定的业务日期；习惯在读取时已换算为归属日。
    let date: Date
    let recordedAt: Date
    let allowsCelebration: Bool
}

nonisolated struct HoloGrowthMilestone: Codable, Identifiable, Equatable, Sendable {
    var metric: HoloGrowthMetric
    var threshold: Int
    /// 业务事实足以还原时才填写，不以首次发现时间冒充历史达成日。
    var achievedAt: Date?
    var discoveredAt: Date
    var id: String { "v1.\(metric.rawValue).\(threshold)" }
    var title: String { metric.milestoneTitle(threshold) }
}

nonisolated struct HoloGrowthProgress: Identifiable, Sendable {
    let metric: HoloGrowthMetric
    /// 天数系列为已去重日期；想法系列每条一项。
    let dates: [Date]
    let latestRecordedAt: Date?
    let freshManualRecord: Bool
    var id: String { metric.id }
    var count: Int { dates.count }
    var nextThreshold: Int? { metric.thresholds.first { $0 > count } }
    var fraction: Double { nextThreshold.map { Double(count) / Double($0) } ?? 1 }
}

nonisolated struct HoloGrowthSnapshot: Sendable {
    let progress: [HoloGrowthProgress]
    let recordedDays: Int
    let updatedAt: Date
    func value(_ metric: HoloGrowthMetric) -> HoloGrowthProgress {
        progress.first { $0.metric == metric } ?? HoloGrowthProgress(metric: metric, dates: [], latestRecordedAt: nil, freshManualRecord: false)
    }
    var next: HoloGrowthProgress? {
        progress.filter { $0.count > 0 && $0.nextThreshold != nil }.sorted {
            if $0.latestRecordedAt != $1.latestRecordedAt { return ($0.latestRecordedAt ?? .distantPast) > ($1.latestRecordedAt ?? .distantPast) }
            if $0.fraction != $1.fraction { return $0.fraction > $1.fraction }
            return $0.metric.rawValue < $1.metric.rawValue
        }.first
    }
}

nonisolated enum HoloGrowthRules {
    static func snapshot(facts: [HoloGrowthMetric: [HoloGrowthFact]], now: Date, calendar: Calendar = .current) -> HoloGrowthSnapshot {
        let today = calendar.startOfDay(for: now)
        var allDays = Set<Date>()
        let progress = HoloGrowthMetric.allCases.map { metric in
            // UUID 副本只算一次，且顺序不影响投影结果。
            let unique = Dictionary((facts[metric] ?? []).map { ($0.id, $0) }, uniquingKeysWith: {
                $0.recordedAt >= $1.recordedAt ? $0 : $1
            }).values.filter { calendar.startOfDay(for: $0.date) <= today }
            let sourceDates = unique.map { calendar.startOfDay(for: $0.date) }
            allDays.formUnion(sourceDates)
            let dates = (metric == .thought ? sourceDates : Array(Set(sourceDates))).sorted()
            let recentManual = unique.contains {
                $0.allowsCelebration && calendar.startOfDay(for: $0.date) == today &&
                $0.recordedAt <= now && now.timeIntervalSince($0.recordedAt) < 60
            }
            return HoloGrowthProgress(metric: metric, dates: dates,
                                      latestRecordedAt: unique.map(\.recordedAt).max(), freshManualRecord: recentManual)
        }
        return HoloGrowthSnapshot(progress: progress, recordedDays: allDays.count, updatedAt: now)
    }

    /// 已颁发事件不可因当前数字下降消失；同一指标/档位永远使用稳定身份。
    static func reconcile(_ existing: [HoloGrowthMilestone], snapshot: HoloGrowthSnapshot) -> [HoloGrowthMilestone] {
        var events = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: merge)
        for progress in snapshot.progress {
            for threshold in progress.metric.thresholds where threshold <= progress.count {
                let event = HoloGrowthMilestone(metric: progress.metric, threshold: threshold,
                                                achievedAt: progress.dates[threshold - 1], discoveredAt: snapshot.updatedAt)
                if events[event.id] == nil { events[event.id] = event }
            }
        }
        return events.values.sorted {
            let lhs = $0.achievedAt ?? $0.discoveredAt, rhs = $1.achievedAt ?? $1.discoveredAt
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }

    static func merge(_ lhs: HoloGrowthMilestone, _ rhs: HoloGrowthMilestone) -> HoloGrowthMilestone {
        var result = lhs.discoveredAt <= rhs.discoveredAt ? lhs : rhs
        result.achievedAt = [lhs.achievedAt, rhs.achievedAt].compactMap { $0 }.min()
        return result
    }

    /// 首次统计、同步、补记、导入和跨多档变化静默；仅当前单步增长可轻提示。
    static func celebration(previous: HoloGrowthSnapshot?, current: HoloGrowthSnapshot,
                            existing: [HoloGrowthMilestone], events: [HoloGrowthMilestone],
                            localMetric: HoloGrowthMetric?) -> HoloGrowthMilestone? {
        guard let previous, let metric = localMetric else { return nil }
        let before = previous.value(metric).count, after = current.value(metric)
        guard after.count == before + 1, after.freshManualRecord else { return nil }
        let known = Set(existing.map(\.id))
        return events.first { $0.metric == metric && $0.threshold == after.count && !known.contains($0.id) }
    }
}
