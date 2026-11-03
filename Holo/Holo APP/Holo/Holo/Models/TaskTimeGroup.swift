//
//  TaskTimeGroup.swift
//  Holo
//
//  任务按到期时间的展示分组（过期置顶，远期组默认折叠降噪）。
//  2026-10-28 从 TaskListView.swift 抽离为共享文件：HoloMac 任务工作台
//  中栏与 iOS 任务列表共用同一套时间分组语义（定义唯一事实源）。
//

import SwiftUI

enum TaskTimeGroup: String, CaseIterable, Hashable {
    case overdue
    case today
    case tomorrow
    case thisWeek
    case later
    case unscheduled

    var title: String {
        switch self {
        case .overdue: return String(localized: "已过期")
        case .today: return String(localized: "今天")
        case .tomorrow: return String(localized: "明天")
        case .thisWeek: return String(localized: "本周")
        case .later: return String(localized: "稍后")
        case .unscheduled: return String(localized: "未安排")
        }
    }

    var dotColor: Color {
        switch self {
        case .overdue: return .holoError
        case .today: return .holoPrimary
        case .tomorrow: return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .thisWeek: return Color(red: 0.77, green: 0.77, blue: 0.77)
        case .later: return Color(red: 0.89, green: 0.89, blue: 0.89)
        case .unscheduled: return Color(red: 0.89, green: 0.89, blue: 0.89)
        }
    }

    /// 远期组默认折叠：首屏聚焦「现在的事」
    var foldsByDefault: Bool {
        switch self {
        case .thisWeek, .later, .unscheduled: return true
        default: return false
        }
    }

    /// 纯按时间归类（不看成败——今日视图里已完成任务也要留在组内展示）
    static func group(for task: TodoTask) -> TaskTimeGroup {
        if task.isOverdue { return .overdue }
        if task.isDueToday { return .today }
        if task.isDueTomorrow { return .tomorrow }
        if let due = task.dueDate,
           Calendar.current.isDate(due, equalTo: Date(), toGranularity: .weekOfYear) {
            return .thisWeek
        }
        if task.dueDate != nil { return .later }
        return .unscheduled
    }
}
