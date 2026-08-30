//
//  HoloScheduleDataSource.swift
//  Holo
//
//  生产数据源：桥接 ScheduleStore（MainActor）→ HoloScheduleTool 的 Sendable 协议。
//  日历未开启/未授权时返回 nil（工具层转空态语义，不报错打断对话）。
//

import Foundation

struct HoloDefaultScheduleDataSource: HoloScheduleDataSource {

    func events(from startDate: Date, days: Int) async -> [HoloScheduleToolEvent]? {
        let store = await MainActor.run { ScheduleStore.shared }
        guard await store.isAvailableForAgent else { return nil }

        let calendar = Calendar.current
        var result: [HoloScheduleToolEvent] = []
        for offset in 0..<max(1, days) {
            let day = calendar.date(byAdding: .day, value: offset, to: startDate) ?? startDate
            let items = await store.fetchSchedules(onDay: day)
            result.append(contentsOf: items.map { event in
                HoloScheduleToolEvent(
                    title: event.title,
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarTitle: event.calendarTitle
                )
            })
        }
        return result
    }
}
