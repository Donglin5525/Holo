//
//  WeeklyGridEventLayout.swift
//  Holo
//
//  周历网格展示布局：避免同时间事件重叠，并把凌晨记录放入边界桶。
//

import CoreGraphics
import Foundation

struct WeeklyGridEventLayout {
    struct VisibleItem: Identifiable {
        let event: CalendarEvent
        let top: CGFloat
        let lane: Int
        let laneCount: Int

        var id: UUID { event.id }
    }

    struct DisplayItem: Identifiable {
        let id = UUID()
        let module: CalendarModule
        let events: [CalendarEvent]
        let top: CGFloat
        let lane: Int
        let laneCount: Int
        let isSummary: Bool
        let stackIndex: Int
        let stackCount: Int

        var primaryEvent: CalendarEvent { events[0] }

        var displayTitle: String {
            if isSummary {
                return "\(module.displayName) +\(events.count)"
            }
            let base = primaryEvent.title
            return events.count > 1 ? "\(base) +\(events.count)" : base
        }
    }

    let early: [CalendarEvent]
    let collapsed: [CalendarEvent]
    let visible: [VisibleItem]
    let displayItems: [DisplayItem]

    static func layout(events: [CalendarEvent],
                       startHour: Int,
                       endHour: Int,
                       hourHeight: CGFloat,
                       collapsedHours: Range<Int>? = nil,
                       minimumSeparation: CGFloat = 28) -> WeeklyGridEventLayout {
        let calendar = Calendar.current
        let sorted = events.sorted { $0.date < $1.date }
        let collapsed = sorted.filter { event in
            guard let collapsedHours else { return false }
            return collapsedHours.contains(calendar.component(.hour, from: event.date))
        }
        let early = sorted.filter { event in
            let hour = calendar.component(.hour, from: event.date)
            return hour < startHour && !(collapsedHours?.contains(hour) ?? false)
        }
        let candidates = sorted.filter { event in
            let hour = calendar.component(.hour, from: event.date)
            return hour >= startHour && hour <= endHour && !(collapsedHours?.contains(hour) ?? false)
        }

        var clusters: [[(event: CalendarEvent, top: CGFloat)]] = []
        for event in candidates {
            let top = topOffset(for: event, startHour: startHour, hourHeight: hourHeight)
            if let last = clusters.indices.last,
               let clusterTop = clusters[last].last?.top,
               abs(top - clusterTop) < minimumSeparation {
                clusters[last].append((event, top))
            } else {
                clusters.append([(event, top)])
            }
        }

        let visible = clusters.flatMap { cluster in
            cluster.enumerated().map { index, item in
                VisibleItem(
                    event: item.event,
                    top: item.top,
                    lane: index,
                    laneCount: cluster.count
                )
            }
        }

        let displayItems = makeDisplayItems(
            from: candidates,
            startHour: startHour,
            hourHeight: hourHeight
        )

        return WeeklyGridEventLayout(
            early: early,
            collapsed: collapsed,
            visible: visible,
            displayItems: displayItems
        )
    }

    private static func makeDisplayItems(from events: [CalendarEvent],
                                         startHour: Int,
                                         hourHeight: CGFloat) -> [DisplayItem] {
        let calendar = Calendar.current
        let hourlyGroups = Dictionary(grouping: events) { event in
            calendar.component(.hour, from: event.date)
        }

        return hourlyGroups.keys.sorted().flatMap { hour in
            let hourEvents = (hourlyGroups[hour] ?? []).sorted { $0.date < $1.date }
            let groups = Dictionary(grouping: hourEvents) { $0.module }
                .map { (module: $0.key, events: $0.value.sorted { $0.date < $1.date }) }
                .sorted { $0.module.rawValue < $1.module.rawValue }
            let multiModule = groups.count > 1
            let stackCount = max(1, groups.count)
            let stackStep = multiModule ? hourHeight / CGFloat(stackCount) : 0
            let hourTop = CGFloat(hour - startHour) * hourHeight

            return groups.enumerated().map { index, group in
                DisplayItem(
                    module: group.module,
                    events: group.events,
                    top: hourTop + CGFloat(index) * stackStep,
                    lane: 0,
                    laneCount: 1,
                    isSummary: multiModule,
                    stackIndex: multiModule ? index : 0,
                    stackCount: multiModule ? stackCount : 1
                )
            }
        }
    }

    private static func topOffset(for event: CalendarEvent,
                                  startHour: Int,
                                  hourHeight: CGFloat) -> CGFloat {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.hour, .minute], from: event.date)
        let hour = comps.hour ?? startHour
        return CGFloat(hour - startHour) * hourHeight
            + CGFloat(comps.minute ?? 0) / 60.0 * hourHeight
    }
}
