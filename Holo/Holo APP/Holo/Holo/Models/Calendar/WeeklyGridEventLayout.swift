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

    let early: [CalendarEvent]
    let visible: [VisibleItem]

    static func layout(events: [CalendarEvent],
                       startHour: Int,
                       endHour: Int,
                       hourHeight: CGFloat,
                       minimumSeparation: CGFloat = 28) -> WeeklyGridEventLayout {
        let calendar = Calendar.current
        let sorted = events.sorted { $0.date < $1.date }
        let early = sorted.filter { calendar.component(.hour, from: $0.date) < startHour }
        let candidates = sorted.filter { event in
            let hour = calendar.component(.hour, from: event.date)
            return hour >= startHour && hour <= endHour
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

        return WeeklyGridEventLayout(early: early, visible: visible)
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
