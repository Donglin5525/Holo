//
//  WeeklyGridEventLayout.swift
//  Holo
//
//  周历网格展示布局：按小时顺序展开事件，并把超出上限的记录放入完整清单入口。
//

import CoreGraphics
import Foundation

struct WeeklyGridEventLayout {
    /// 单条事件块的固定几何：块高与字号不随缩放变化，缩放只改变每小时能容纳的条数
    private static let eventPitch: CGFloat = 27
    private static let eventBlockHeight: CGFloat = 24
    private static let singleEventTopPadding: CGFloat = 9
    private static let multiEventTopPadding: CGFloat = 3
    private static let overflowHeight: CGFloat = 17

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

    /// 该小时高度下能直显的条数。1.0× 时与分档表一一对应
    /// （42→1、57→2、84→3、111→4、131→4+溢出），不缩放则视觉零回归。
    static func visibleCapacity(hourHeight: CGFloat) -> Int {
        guard hourHeight >= eventPitch else { return 1 }
        return Int((hourHeight - eventPitch) / eventPitch) + 1
    }

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
            axisProfile: axisProfile
        )

        return WeeklyGridEventLayout(
            early: early,
            collapsed: collapsed,
            displayItems: displayItems
        )
    }

    private static func makeDisplayItems(from events: [CalendarEvent],
                                         axisProfile: WeeklyGridAxisProfile) -> [DisplayItem] {
        let calendar = Calendar.current
        let hourlyGroups = Dictionary(grouping: events) { event in
            calendar.component(.hour, from: event.date)
        }

        return hourlyGroups.keys.sorted().flatMap { hour in
            let hourEvents = (hourlyGroups[hour] ?? []).sorted(by: eventComesBefore)
            let hourHeight = axisProfile.height(for: hour)
            let rawCapacity = visibleCapacity(hourHeight: hourHeight)
            // 放大时间轴后单小时可能容纳十余条记录；一旦仍有溢出，需要先为“还有 N 条”
            // 入口预留高度，否则极限密度下最后一行会越过本小时边界。
            let capacity: Int
            if hourEvents.count > rawCapacity {
                let capacityWithOverflow = Int(
                    floor((hourHeight - multiEventTopPadding - overflowHeight) / eventPitch)
                )
                capacity = max(1, min(rawCapacity, capacityWithOverflow))
            } else {
                capacity = rawCapacity
            }
            let visibleEvents = Array(hourEvents.prefix(capacity))
            let hourTop = axisProfile.top(for: hour)
            let topPadding: CGFloat = visibleEvents.count <= 1 ? singleEventTopPadding : multiEventTopPadding
            var items = visibleEvents.enumerated().map { index, event in
                DisplayItem(
                    id: "event-\(event.id.uuidString)",
                    module: event.module,
                    events: [event],
                    top: hourTop + topPadding + CGFloat(index) * eventPitch,
                    height: eventBlockHeight,
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
                        top: hourTop + topPadding + CGFloat(visibleEvents.count) * eventPitch,
                        height: overflowHeight,
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
