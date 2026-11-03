//
//  TaskCalendarProjection.swift
//  Holo
//
//  日历投影纯计算（多视图方案 §4.2/§4.4/§5）：P(D)=当日开始计划、C(D)=当日截止、
//  U(D)=并集去重；月历数字=|U(D)|；占用=时段并集；待安排=无合法计划（与截止无关）。
//  半缺/非法计划按未安排处理且有截止仍可见；一切从纯值快照计算，不反查 Core Data。
//

import Foundation

nonisolated enum TaskCalendarProjection {

    // MARK: - 单任务事实

    /// 合法计划时段（半缺/非法 → nil，§4.2）
    static func validPlannedRange(of snapshot: TaskRecordSnapshot) -> (start: Date, end: Date)? {
        guard snapshot.hasValidPlannedRange,
              let start = snapshot.plannedStart, let end = snapshot.plannedEnd else { return nil }
        return (start, end)
    }

    /// 计划开始日（本地自然日；无合法计划 → nil）
    static func plannedDay(of snapshot: TaskRecordSnapshot, calendar: Calendar) -> Date? {
        guard let range = validPlannedRange(of: snapshot) else { return nil }
        return calendar.startOfDay(for: range.start)
    }

    /// 截止日（原始日期的本地日比较，§4.2；全天截止已在 effectiveDue 策略内解释为日末）
    static func dueDay(of snapshot: TaskRecordSnapshot, calendar: Calendar) -> Date? {
        guard let due = snapshot.dueDate else { return nil }
        return calendar.startOfDay(for: due)
    }

    // MARK: - 单日投影

    struct DayProjection {
        let day: Date
        /// 日明细全列表（§4.4：当日计划任务先按开始升序，其后截止独立项按有效截止）
        let members: [TaskRecordSnapshot]
        /// 当日有合法计划时段的任务（时间轴块）
        let plannedMembers: [TaskRecordSnapshot]
        /// 当日截止且当日无计划块的任务（截止事项区，§5.2-3）
        let dueOnlyMembers: [TaskRecordSnapshot]
        /// 计划时段并集占用分钟数（§5.1-7：不重复累加冲突时间）
        let occupiedMinutes: Int
    }

    static func dayProjection(
        day: Date,
        members: [TaskRecordSnapshot],
        now: Date,
        calendar: Calendar
    ) -> DayProjection {
        let dayStart = calendar.startOfDay(for: day)
        var planned: [TaskRecordSnapshot] = []
        var dueOnly: [TaskRecordSnapshot] = []
        var seen = Set<UUID>()
        var unionRanges: [(start: Date, end: Date)] = []

        for snapshot in members where !seen.contains(snapshot.id) {
            let onPlanDay = plannedDay(of: snapshot, calendar: calendar) == dayStart
            let onDueDay = dueDay(of: snapshot, calendar: calendar) == dayStart
            guard onPlanDay || onDueDay else { continue }
            seen.insert(snapshot.id)
            if onPlanDay {
                planned.append(snapshot)
                if let range = validPlannedRange(of: snapshot) {
                    unionRanges.append(range)
                }
            } else {
                dueOnly.append(snapshot)
            }
        }

        let plannedSorted = planned.sorted { lhs, rhs in
            let lStart = lhs.plannedStart ?? .distantPast
            let rStart = rhs.plannedStart ?? .distantPast
            if lStart != rStart { return lStart < rStart }
            let lEnd = lhs.plannedEnd ?? .distantFuture
            let rEnd = rhs.plannedEnd ?? .distantFuture
            if lEnd != rEnd { return lEnd < rEnd }
            return TaskRecordSnapshot.defaultOrder(lhs, rhs, now: now, calendar: calendar)
        }
        let dueSorted = dueOnly.sorted { lhs, rhs in
            let lDue = lhs.effectiveDue(calendar: calendar) ?? .distantFuture
            let rDue = rhs.effectiveDue(calendar: calendar) ?? .distantFuture
            if lDue != rDue { return lDue < rDue }
            return TaskRecordSnapshot.defaultOrder(lhs, rhs, now: now, calendar: calendar)
        }

        return DayProjection(
            day: dayStart,
            members: plannedSorted + dueSorted,
            plannedMembers: plannedSorted,
            dueOnlyMembers: dueSorted,
            occupiedMinutes: unionMinutes(unionRanges, calendar: calendar)
        )
    }

    /// 月历格数字：|U(D)|（同任务同日计划+截止两个事实只计一次，§4.2）
    static func dayCount(
        day: Date,
        members: [TaskRecordSnapshot],
        calendar: Calendar
    ) -> Int {
        let dayStart = calendar.startOfDay(for: day)
        var ids = Set<UUID>()
        for snapshot in members {
            if plannedDay(of: snapshot, calendar: calendar) == dayStart
                || dueDay(of: snapshot, calendar: calendar) == dayStart {
                ids.insert(snapshot.id)
            }
        }
        return ids.count
    }

    /// 整月（或任意日期序列）一次索引：网格逐日数字不逐格全量扫描（P01）
    static func dayCounts(
        days: [Date],
        members: [TaskRecordSnapshot],
        calendar: Calendar
    ) -> [Date: Int] {
        // 先建 日期 → id 集合 索引（计划与截止同一桶，Set 天然去重）
        var index: [Date: Set<UUID>] = [:]
        func touch(_ day: Date?, _ id: UUID) {
            guard let day else { return }
            index[day, default: []].insert(id)
        }
        for snapshot in members {
            touch(plannedDay(of: snapshot, calendar: calendar), snapshot.id)
            touch(dueDay(of: snapshot, calendar: calendar), snapshot.id)
        }
        var result: [Date: Int] = [:]
        for day in days {
            let start = calendar.startOfDay(for: day)
            result[start] = index[start]?.count ?? 0
        }
        return result
    }

    // MARK: - 待安排 / 逾期（§5.3）

    /// 待安排：无合法计划时段（与有无截止无关；有效但已过去的计划仍算安排过）
    static func unplannedMembers(
        from members: [TaskRecordSnapshot],
        now: Date,
        calendar: Calendar
    ) -> [TaskRecordSnapshot] {
        members
            .filter { validPlannedRange(of: $0) == nil }
            .sorted { TaskRecordSnapshot.defaultOrder($0, $1, now: now, calendar: calendar) }
    }

    /// 逾期：有效截止 < asOf 的活动任务（与计划是否过去无关；含已安排但逾期）
    static func overdueMembers(
        from members: [TaskRecordSnapshot],
        asOf: Date,
        calendar: Calendar
    ) -> [TaskRecordSnapshot] {
        members
            .filter { !$0.completed && $0.isOverdue(asOf: asOf, calendar: calendar) }
            .sorted { TaskRecordSnapshot.defaultOrder($0, $1, now: asOf, calendar: calendar) }
    }

    // MARK: - 占用并集（§5.1-7）

    /// 时段并集分钟数：区间扫描合并，不重复累加冲突时间
    static func unionMinutes(_ ranges: [(start: Date, end: Date)], calendar: Calendar) -> Int {
        let sorted = ranges.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard let first = sorted.first else { return 0 }
        var total = 0
        var currentStart = first.start
        var currentEnd = first.end
        for range in sorted.dropFirst() {
            if range.start < currentEnd {
                if range.end > currentEnd { currentEnd = range.end }
            } else {
                total += calendar.dateComponents([.minute], from: currentStart, to: currentEnd).minute ?? 0
                currentStart = range.start
                currentEnd = range.end
            }
        }
        total += calendar.dateComponents([.minute], from: currentStart, to: currentEnd).minute ?? 0
        return total
    }
}
