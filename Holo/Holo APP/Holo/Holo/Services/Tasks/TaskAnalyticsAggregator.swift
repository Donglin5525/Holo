//
//  TaskAnalyticsAggregator.swift
//  Holo
//
//  纯聚合器（方案 §7.3–§7.9）：输入唯一任务快照集合 + 周期边界 + 冻结 asOf/日历，
//  一次产出完整统计快照。指标、桶、分布、明细共用同一份 UUID 集合；
//  无任何 I/O，桶合计恒等于指标总数由构造保证。
//

import Foundation

nonisolated enum TaskAnalyticsAggregator {

    /// 生成完整统计快照（所有内容绑定同一 asOf 与唯一任务集合，方案 §7.10）
    static func aggregate(
        snapshots: [TaskRecordSnapshot],
        period: TaskAnalyticsPeriod,
        asOf: Date,
        calendar: Calendar
    ) -> TaskAnalyticsSnapshot {
        let bounds = TaskAnalyticsPeriodResolver.bounds(of: period, asOf: asOf, calendar: calendar)
        let compareWindow = TaskAnalyticsPeriodResolver.compareWindow(current: bounds, asOf: asOf, calendar: calendar)

        // ---- 唯一未删除任务（快照读取端已完成副本选择，此处只过滤删除契约）----
        let alive = snapshots.filter { !$0.deleted }

        // ---- 新增 / 完成（§7.4）----
        let created = alive.filter {
            $0.createdAt >= bounds.start && $0.createdAt < bounds.endExclusive && $0.createdAt <= asOf
        }
        let completed = alive.filter { snapshot in
            guard snapshot.completed, let completedAt = snapshot.completedAt else { return false }
            return completedAt >= bounds.start && completedAt < bounds.endExclusive && completedAt <= asOf
        }

        // ---- 完成时间缺失（全部未删除口径，无法归属期间）与时钟异常（§7.4）----
        let missingCompletedAt = alive.filter { $0.completed && $0.completedAt == nil }
        let futureCompletedAt = alive.filter { snapshot in
            guard let completedAt = snapshot.completedAt else { return false }
            return completedAt > asOf
        }

        // ---- 按时率：同一批成熟到期任务（§7.5）----
        let maturedCandidates = alive.filter { snapshot in
            guard let due = snapshot.effectiveDue(calendar: calendar) else { return false }
            return due >= bounds.start && due < bounds.endExclusive && due <= asOf
        }
        let excludedX = maturedCandidates.filter { $0.completed && $0.completedAt == nil }
        let denominatorE = maturedCandidates.filter { !($0.completed && $0.completedAt == nil) }
        let onTimeO = denominatorE.filter { snapshot in
            guard let completedAt = snapshot.completedAt else { return false }
            let due = snapshot.effectiveDue(calendar: calendar)!
            return completedAt <= due && completedAt <= asOf
        }
        let lateIDs = denominatorE.filter { snapshot in
            guard snapshot.completed, let completedAt = snapshot.completedAt else { return false }
            let due = snapshot.effectiveDue(calendar: calendar)!
            return completedAt > due
        }.map(\.id)
        let unfinishedIDs = denominatorE.filter { !$0.completed }.map(\.id)
        let onTimeStats = TaskOnTimeStats(
            denominatorIDs: denominatorE.map(\.id),
            onTimeIDs: onTimeO.map(\.id),
            lateIDs: lateIDs,
            unfinishedIDs: unfinishedIDs,
            excludedMissingTimeIDs: excludedX.map(\.id)
        )

        // ---- 对比：同等已过窗口内的数量差（§7.6）----
        let prevCreated = alive.filter {
            $0.createdAt >= compareWindow.previousStart && $0.createdAt < compareWindow.previousEnd
        }.count
        let prevCompleted = alive.filter { snapshot in
            guard snapshot.completed, let completedAt = snapshot.completedAt else { return false }
            return completedAt >= compareWindow.previousStart && completedAt < compareWindow.previousEnd
        }.count
        let comparison = TaskAnalyticsComparison(
            createdDelta: created.count - prevCreated,
            completedDelta: completed.count - prevCompleted,
            truncatedToPreviousEnd: compareWindow.truncatedToPreviousEnd
        )

        // ---- 趋势桶（§7.7：桶合计 = 指标总数，未来桶只标不计）----
        let buckets = TaskAnalyticsPeriodResolver.buckets(of: bounds, asOf: asOf, calendar: calendar)
            .map { bucket -> TaskAnalyticsBucketStat in
                let bucketCreated = created.filter {
                    $0.createdAt >= bucket.start && $0.createdAt < bucket.endExclusive
                }.map(\.id)
                let bucketCompleted = completed.filter { snapshot in
                    guard let at = snapshot.completedAt else { return false }
                    return at >= bucket.start && at < bucket.endExclusive
                }.map(\.id)
                return TaskAnalyticsBucketStat(
                    start: bucket.start,
                    endExclusive: bucket.endExclusive,
                    createdIDs: bucketCreated,
                    completedIDs: bucketCompleted,
                    isFuture: bucket.isFuture,
                    isPartialToday: bucket.isPartialToday
                )
            }

        // ---- 清单分布（完成集合按当前有效清单分组，§7.8）----
        var breakdown: [String: (listID: UUID?, name: String, ids: [UUID], archived: Bool)] = [:]
        for snapshot in completed {
            let key: String
            let name: String
            let listArchived: Bool
            if let listID = snapshot.listID {
                key = listID.uuidString
                name = snapshot.listAvailable
                    ? (snapshot.listName ?? String(localized: "未归属清单"))
                    : String(localized: "未归属清单")
                listArchived = snapshot.listIsArchived
            } else {
                key = "inbox"
                name = String(localized: "收件箱")
                listArchived = false
            }
            if let existing = breakdown[key] {
                breakdown[key] = (existing.listID, existing.name, existing.ids + [snapshot.id], listArchived || existing.archived)
            } else {
                breakdown[key] = (snapshot.listID, name, [snapshot.id], listArchived)
            }
        }
        let listBreakdown = breakdown
            .map { key, value in
                TaskListBreakdownStat(
                    id: key,
                    listID: value.listID,
                    name: value.name,
                    completedIDs: value.ids,
                    listIsArchived: value.archived
                )
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.id < rhs.id
            }

        // ---- 当前待处理（截至现在，不随期间过滤，§7.9）----
        let active = alive.filter { !$0.archived && !$0.completed }
        let attention = TaskCurrentAttention(
            overdueIDs: active
                .filter { $0.isOverdue(asOf: asOf, calendar: calendar) }
                .map(\.id),
            importantUnscheduledIDs: active
                .filter { $0.importance == .p1 && !$0.hasValidPlannedRange }
                .map(\.id),
            unclassifiedIDs: active
                .filter { $0.importance == .unknown }
                .map(\.id)
        )

        return TaskAnalyticsSnapshot(
            asOf: asOf,
            period: period,
            start: bounds.start,
            endExclusive: bounds.endExclusive,
            isOngoing: bounds.isOngoing,
            createdIDs: created.map(\.id),
            completedIDs: completed.map(\.id),
            comparison: comparison,
            onTime: onTimeStats,
            missingCompletedAtIDs: missingCompletedAt.map(\.id),
            futureCompletedAtIDs: futureCompletedAt.map(\.id),
            buckets: buckets,
            listBreakdown: listBreakdown,
            attention: attention
        )
    }
}
