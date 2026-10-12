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

        // ---- 对比：同等已过窗口内的数量差（§7.6）+ 到期两率环比 ----
        let prevCreated = alive.filter {
            $0.createdAt >= compareWindow.previousStart && $0.createdAt < compareWindow.previousEnd
        }.count
        let prevCompleted = alive.filter { snapshot in
            guard snapshot.completed, let completedAt = snapshot.completedAt else { return false }
            return completedAt >= compareWindow.previousStart && completedAt < compareWindow.previousEnd
        }.count
        let prevDue = dueOutcomeCounts(
            alive,
            dueRange: compareWindow.previousStart..<compareWindow.previousEnd,
            asOf: asOf,
            calendar: calendar
        )
        let prevDueDenominator = prevDue.matured - prevDue.excluded
        func prevRate(_ numerator: Int) -> Double? {
            prevDueDenominator > 0 ? Double(numerator) / Double(prevDueDenominator) : nil
        }
        let comparison = TaskAnalyticsComparison(
            createdDelta: created.count - prevCreated,
            completedDelta: completed.count - prevCompleted,
            truncatedToPreviousEnd: compareWindow.truncatedToPreviousEnd,
            previousDueCompletionRate: prevRate(prevDue.onTime + prevDue.late),
            previousOnTimeRate: prevRate(prevDue.onTime)
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
                let bucketDue = dueOutcomeCounts(
                    alive,
                    dueRange: bucket.start..<bucket.endExclusive,
                    asOf: asOf,
                    calendar: calendar
                )
                return TaskAnalyticsBucketStat(
                    start: bucket.start,
                    endExclusive: bucket.endExclusive,
                    createdIDs: bucketCreated,
                    completedIDs: bucketCompleted,
                    isFuture: bucket.isFuture,
                    isPartialToday: bucket.isPartialToday,
                    maturedDueCount: bucketDue.matured,
                    onTimeDueCount: bucketDue.onTime,
                    lateDueCount: bucketDue.late,
                    excludedDueMissingTimeCount: bucketDue.excluded
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

        // ---- 完成节奏热力网格（P2：固定近 12 个自然周，不随档位，从全体存活任务取数）----
        // （局部常量 bounds 与解析器方法同名，这里显式走 TaskAnalyticsPeriodResolver）
        let currentWeekStart = TaskAnalyticsPeriodResolver.bounds(of: .week(anchorDay: asOf), asOf: asOf, calendar: calendar).start
        let heatStart = calendar.date(byAdding: .weekOfYear, value: -11, to: currentWeekStart)!
        var heatDays: [TaskDailyCompletionCount] = []
        while heatDays.count < 84 {
            let dayStart = calendar.date(byAdding: .day, value: heatDays.count, to: heatStart)!
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
            let dayCount = alive.filter { snapshot in
                guard let at = snapshot.completedAt else { return false }
                return at >= dayStart && at < dayEnd && at <= asOf
            }.count
            heatDays.append(TaskDailyCompletionCount(start: dayStart, completedCount: dayCount))
        }

        // ---- 完成时刻分布（P2：本期完成集合按 0–23 时落桶）----
        var hourly = Array(repeating: 0, count: 24)
        for snapshot in completed {
            guard let at = snapshot.completedAt else { continue }
            hourly[calendar.component(.hour, from: at)] += 1
        }

        // ---- 按事项分组（P2：本期完成集合按已链接事项分桶；一任务多事项重复计入）----
        var matterBuckets: [UUID: (title: String, ids: [UUID])] = [:]
        for snapshot in completed {
            let linkedMatterIDs = Set(snapshot.matterLinks.map(\.matterID)).sorted { $0.uuidString < $1.uuidString }
            for matterID in linkedMatterIDs {
                guard let fact = snapshot.matterLinks.first(where: { $0.matterID == matterID }) else { continue }
                if var bucket = matterBuckets[matterID] {
                    bucket.ids.append(snapshot.id)
                    matterBuckets[matterID] = bucket
                } else {
                    matterBuckets[matterID] = (fact.title, [snapshot.id])
                }
            }
        }
        let matterBreakdown = matterBuckets
            .map { matterID, value in
                TaskMatterBreakdownStat(id: matterID, title: value.title, completedIDs: value.ids)
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.id.uuidString < rhs.id.uuidString
            }

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
            attention: attention,
            heatDays: heatDays,
            hourlyCompletedCounts: hourly,
            matterBreakdown: matterBreakdown
        )
    }

    /// 一批任务在给定到期窗口内的成熟结果计数（§7.5 同口径：窗口内成熟到期、
    /// 排除「已完成但缺完成时间」；按时含跨期提前完成的命中）
    private static func dueOutcomeCounts(
        _ snapshots: [TaskRecordSnapshot],
        dueRange: Range<Date>,
        asOf: Date,
        calendar: Calendar
    ) -> (matured: Int, excluded: Int, onTime: Int, late: Int) {
        let matured = snapshots.filter { snapshot in
            guard let due = snapshot.effectiveDue(calendar: calendar) else { return false }
            return dueRange.contains(due) && due <= asOf
        }
        let excluded = matured.filter { $0.completed && $0.completedAt == nil }
        let denominator = matured.filter { !($0.completed && $0.completedAt == nil) }
        let onTime = denominator.filter { snapshot in
            guard let completedAt = snapshot.completedAt else { return false }
            return completedAt <= snapshot.effectiveDue(calendar: calendar)! && completedAt <= asOf
        }.count
        let late = denominator.filter { snapshot in
            guard snapshot.completed, let completedAt = snapshot.completedAt else { return false }
            return completedAt > snapshot.effectiveDue(calendar: calendar)!
        }.count
        return (matured.count, excluded.count, onTime, late)
    }
}
