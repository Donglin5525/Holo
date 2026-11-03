//
//  TaskAnalyticsSnapshot.swift
//  Holo
//
//  统计聚合的结果值类型（方案 §7）：一次请求 = 同一 asOf/日历/唯一任务集合，
//  指标、对比、趋势、清单分布、当前待处理与明细 UUID 全部从同一聚合结果派生。
//

import Foundation

// MARK: - 按时率

/// 按时完成率明细（同一批到期任务的结果，方案 §7.5）
nonisolated struct TaskOnTimeStats: Equatable, Sendable {
    /// 有效分母 E：成熟截止候选排除「已完成但缺完成时间」
    let denominatorIDs: [UUID]
    /// 按时集合 O
    let onTimeIDs: [UUID]
    /// 延迟完成（分母内）
    let lateIDs: [UUID]
    /// 分母内未完成（必须留在分母，方案 §7.5）
    let unfinishedIDs: [UUID]
    /// 缺失完成时间被排除的 X（D 内）
    let excludedMissingTimeIDs: [UUID]

    var denominatorCount: Int { denominatorIDs.count }
    var onTimeCount: Int { onTimeIDs.count }
    var lateCount: Int { lateIDs.count }
    var unfinishedCount: Int { unfinishedIDs.count }
    /// |E| == 0 时无数值（显示「—」），由视图判断 denominatorCount
    var rate: Double? {
        denominatorCount > 0 ? Double(onTimeCount) / Double(denominatorCount) : nil
    }
    /// 到期完成率（按时 + 迟到）÷ 到期分母：「到期的事里完成了几成」，与按时率互补
    var completionRate: Double? {
        denominatorCount > 0
            ? Double(onTimeCount + lateCount) / Double(denominatorCount)
            : nil
    }
}

// MARK: - 对比

nonisolated struct TaskAnalyticsComparison: Equatable, Sendable {
    let createdDelta: Int
    let completedDelta: Int
    /// 上期较短、对比终点截到上期结束（方案 §7.6-4）
    let truncatedToPreviousEnd: Bool
    /// 上期到期完成率 / 按时率（同等已过窗口口径；上期无到期任务时为 nil）
    let previousDueCompletionRate: Double?
    let previousOnTimeRate: Double?
}

// MARK: - 趋势桶

nonisolated struct TaskAnalyticsBucketStat: Equatable, Sendable {
    let start: Date
    let endExclusive: Date
    let createdIDs: [UUID]
    let completedIDs: [UUID]
    let isFuture: Bool
    let isPartialToday: Bool
    /// 到期完成视角（§7.5 同口径逐桶化）：桶内成熟到期候选与结果计数
    let maturedDueCount: Int
    let onTimeDueCount: Int
    let lateDueCount: Int
    let excludedDueMissingTimeCount: Int

    /// 桶内到期完成率 =（按时 + 迟到）÷（成熟候选 − 缺完成时间排除）
    var dueCompletionRate: Double? {
        let denominator = maturedDueCount - excludedDueMissingTimeCount
        return denominator > 0
            ? Double(onTimeDueCount + lateDueCount) / Double(denominator)
            : nil
    }
}

// MARK: - 清单分布

nonisolated struct TaskListBreakdownStat: Equatable, Sendable, Identifiable {
    /// 稳定身份：清单 UUID；收件箱/未归属桶用固定合成 ID
    let id: String
    let listID: UUID?
    let name: String
    let completedIDs: [UUID]
    /// 归档但未删除清单可保留名称并标记（方案 §7.3）
    let listIsArchived: Bool

    var count: Int { completedIDs.count }
}

// MARK: - 事项分布（P2）

nonisolated struct TaskMatterBreakdownStat: Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let completedIDs: [UUID]

    var count: Int { completedIDs.count }
}

// MARK: - 完成节奏（P2）

/// 热力网格单日：按天完成数（固定窗口内逐日，含零完成日）
nonisolated struct TaskDailyCompletionCount: Equatable, Sendable {
    let start: Date
    let completedCount: Int
}

// MARK: - 当前待处理（截至现在，方案 §7.9）

nonisolated struct TaskCurrentAttention: Equatable, Sendable {
    let overdueIDs: [UUID]
    let importantUnscheduledIDs: [UUID]
    let unclassifiedIDs: [UUID]
}

// MARK: - 完整统计快照

nonisolated struct TaskAnalyticsSnapshot: Equatable, Sendable {
    let asOf: Date
    let period: TaskAnalyticsPeriod
    let start: Date
    let endExclusive: Date
    let isOngoing: Bool

    /// 本期新增（唯一未删除、createdAt 落期间且 ≤ asOf）
    let createdIDs: [UUID]
    /// 本期完成（completed、completedAt 落期间且 ≤ asOf）
    let completedIDs: [UUID]
    /// 与上一周期同等已过窗口的数量差
    let comparison: TaskAnalyticsComparison
    let onTime: TaskOnTimeStats
    /// 当前全部未删除「已完成但缺完成时间」记录（无法归属期间，方案 §7.4）
    let missingCompletedAtIDs: [UUID]
    /// 时钟异常的未来完成时间记录（不计已发生事件、留可查数量）
    let futureCompletedAtIDs: [UUID]
    let buckets: [TaskAnalyticsBucketStat]
    let listBreakdown: [TaskListBreakdownStat]
    let attention: TaskCurrentAttention
    /// 完成节奏热力网格：固定近 12 个自然周（84 天，自本周周一起算），不随档位（P2）
    let heatDays: [TaskDailyCompletionCount]
    /// 本期完成时刻分布：24 桶（0–23 时计数）
    let hourlyCompletedCounts: [Int]
    /// 本期完成按事项分组（一任务链接多事项会重复计入各事项，视图需注明；P2）
    let matterBreakdown: [TaskMatterBreakdownStat]

    var createdCount: Int { createdIDs.count }
    var completedCount: Int { completedIDs.count }

    /// 期间观察（确定规则生成，方案 §7.9）
    var observation: String {
        if createdCount == 0 && completedCount == 0 {
            return String(localized: "这个期间还没有新增或完成记录。")
        }
        if createdCount > completedCount {
            let diff = createdCount - completedCount
            return String(localized: "本期新增比完成多 \(diff) 项，可以回看哪些事情需要继续推进。")
        }
        if completedCount > createdCount {
            let diff = completedCount - createdCount
            return String(localized: "本期完成比新增多 \(diff) 项。")
        }
        return String(localized: "本期新增与完成数量相同。")
    }
}
