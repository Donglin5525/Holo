import Foundation

/// 今天只读概览：合回旧主卡占用的任务，保留既有选择与日期事实，不修改日计划。
enum HoloTodayReadOnlyProjection {
    static func agenda(_ snapshot: HoloTodaySnapshot) -> [HoloTodayAgendaItem] {
        var rows: [HoloTodayAgendaItem] = []
        var seen = Set<String>()
        func append(_ item: HoloTodayAgendaItem) {
            guard !item.isCompleted, seen.insert(item.id).inserted else { return }
            rows.append(item)
        }
        for schedule in snapshot.focusInput.schedules where schedule.endAt > snapshot.referenceTime && schedule.startAt < snapshot.dayEnd {
            append(HoloTodayAgendaItem(id: "schedule:\(schedule.id)", kind: schedule.startAt <= snapshot.referenceTime ? .scheduleOngoing : .scheduleUpcoming,
                title: schedule.title, timeAt: schedule.isAllDay ? nil : schedule.startAt, isCompleted: false, matterTitle: "日程", action: .openSchedule(schedule.id)))
        }
        if case .explicit = snapshot.plan.state {
            for row in snapshot.plan.selectionRows {
                guard snapshot.focusInput.tasks.contains(where: { $0.id == row.taskID && !$0.isCompleted }) else { continue }
                append(HoloTodayAgendaItem(id: "task:\(row.taskID.uuidString)", kind: .taskPlannedToday,
                    title: row.title, timeAt: row.dueAt, isCompleted: false, matterTitle: row.stepActionText ?? row.matterTitle, action: .openTask(row.taskID)))
            }
            for row in snapshot.plan.constraintRows {
                guard let id = row.taskID else { continue }
                let date: Date, kind: HoloTodayAgendaKind
                switch row.kind {
                case .schedule: continue
                case .plannedSegment(let start, _): date = start; kind = .taskPlannedToday
                case .deadline(let due, _, let overdue): date = due; kind = overdue ? .taskOverdue : .taskDueToday
                }
                append(HoloTodayAgendaItem(id: "task:\(id.uuidString)", kind: kind, title: row.title,
                    timeAt: date, isCompleted: false, matterTitle: nil, action: .openTask(id)))
            }
        } else {
            if let focus = snapshot.primaryFocus, case .openTask(let id) = focus.action {
                append(HoloTodayAgendaItem(id: "task:\(id.uuidString)", kind: focus.reasonCode == .overdueTask ? .taskOverdue : .taskDueToday,
                    title: focus.title, timeAt: focus.dueAt, isCompleted: false, matterTitle: nil, action: .openTask(id)))
            }
            for item in snapshot.agenda { append(item) }
        }
        return rows
    }
}
