//
//  ScheduleItem.swift
//  Holo
//
//  系统日历日程的值类型快照（只读展示用，与 EKEvent 解耦）
//

import SwiftUI
import EventKit

struct ScheduleItem: Identifiable, Equatable {
    /// eventIdentifier + 发生时刻合成，保证重复日程多场各自唯一（Identifiable）
    let id: String
    let eventIdentifier: String
    /// EKCalendarItem.calendarItemExternalIdentifier：完成态的定位键（跨设备稳定）
    let externalIdentifier: String?
    /// 该场发生日（重复日程区分单场）
    let occurrenceDay: Date

    let calendarIdentifier: String
    let calendarTitle: String
    let calendarColor: Color

    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?

    /// 完成态定位键：外部标识缺失时退回 eventIdentifier（本地日历事件可能无外部标识）
    var completionKey: String {
        externalIdentifier ?? eventIdentifier
    }

    var durationMinutes: Int {
        max(0, Int(endDate.timeIntervalSince(startDate) / 60))
    }

    init(event: EKEvent) {
        let calendar = Calendar.current
        self.eventIdentifier = event.eventIdentifier
        self.externalIdentifier = event.calendarItemExternalIdentifier
        self.occurrenceDay = calendar.startOfDay(for: event.startDate)
        self.calendarIdentifier = event.calendar.calendarIdentifier
        self.calendarTitle = event.calendar.title
        self.calendarColor = Color(event.calendar.cgColor)
        self.title = event.title ?? "未命名日程"
        self.startDate = event.startDate
        self.endDate = event.endDate
        self.isAllDay = event.isAllDay
        self.location = event.location
        self.id = "\(event.eventIdentifier)|\(event.startDate.timeIntervalSince1970)"
    }

    static func == (lhs: ScheduleItem, rhs: ScheduleItem) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.startDate == rhs.startDate
            && lhs.endDate == rhs.endDate
            && lhs.calendarIdentifier == rhs.calendarIdentifier
    }
}
