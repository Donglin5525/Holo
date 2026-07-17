//
//  WeeklyGridEventLayout.swift
//  Holo
//
//  周历网格展示布局：按小时顺序展开事件，并把超出上限的记录放入完整清单入口。
//

import CoreGraphics
import Foundation

struct WeeklyGridEventLayout {
    private static let maximumVisibleEvents = 4

    struct DisplayItem: Identifiable {
        let id: String
        let module: CalendarModule
        let events: [CalendarEvent]
        let top: CGFloat
        let height: CGFloat
        let isOverflow: Bool
        let overflowCount: Int

        var primaryEvent: CalendarEvent { events[0] }

        var displayTitle: String {
            isOverflow ? "还有 \(overflowCount) 条" : primaryEvent.title
        }
    }

    let early: [CalendarEvent]
    let collapsed: [CalendarEvent]
    let displayItems: [DisplayItem]

    static func layout(events: [CalendarEvent],
                       axisProfile: WeeklyGridAxisProfile,
                       collapsedHours: Range<Int>? = nil) -> WeeklyGridEventLayout {
        let calendar = Calendar.current
        let sorted = events.sorted(by: eventComesBefore)
        let collapsed = sorted.filter { event in
            guard let collapsedHours else { return false }
            return collapsedHours.contains(calendar.component(.hour, from: event.date))
        }
        let early = sorted.filter { event in
            let hour = calendar.component(.hour, from: event.date)
            return hour < axisProfile.startHour && !(collapsedHours?.contains(hour) ?? false)
        }
        let candidates = sorted.filter { event in
            let hour = calendar.component(.hour, from: event.date)
            return hour >= axisProfile.startHour
                && hour <= axisProfile.endHour
                && !(collapsedHours?.contains(hour) ?? false)
        }

        let displayItems = makeDisplayItems(
            from: candidates,
            axisProfile: axisProfile,
            maximumVisibleEvents: maximumVisibleEvents
        )

        return WeeklyGridEventLayout(
            early: early,
            collapsed: collapsed,
            displayItems: displayItems
        )
    }

    private static func makeDisplayItems(from events: [CalendarEvent],
                                         axisProfile: WeeklyGridAxisProfile,
                                         maximumVisibleEvents: Int) -> [DisplayItem] {
        let calendar = Calendar.current
        let hourlyGroups = Dictionary(grouping: events) { event in
            calendar.component(.hour, from: event.date)
        }

        return hourlyGroups.keys.sorted().flatMap { hour in
            let hourEvents = (hourlyGroups[hour] ?? []).sorted(by: eventComesBefore)
            let visibleEvents = Array(hourEvents.prefix(maximumVisibleEvents))
            let hourTop = axisProfile.top(for: hour)
            let topPadding: CGFloat = visibleEvents.count <= 1 ? 9 : 3
            var items = visibleEvents.enumerated().map { index, event in
                DisplayItem(
                    id: "event-\(event.id.uuidString)",
                    module: event.module,
                    events: [event],
                    top: hourTop + topPadding + CGFloat(index) * 27,
                    height: 24,
                    isOverflow: false,
                    overflowCount: 0
                )
            }

            let overflowCount = hourEvents.count - visibleEvents.count
            if overflowCount > 0, let first = hourEvents.first {
                items.append(
                    DisplayItem(
                        id: "overflow-\(hour)",
                        module: first.module,
                        events: hourEvents,
                        top: hourTop + 111,
                        height: 17,
                        isOverflow: true,
                        overflowCount: overflowCount
                    )
                )
            }
            return items
        }
    }

    nonisolated private static func eventComesBefore(_ lhs: CalendarEvent, _ rhs: CalendarEvent) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        if lhs.module.rawValue != rhs.module.rawValue { return lhs.module.rawValue < rhs.module.rawValue }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
