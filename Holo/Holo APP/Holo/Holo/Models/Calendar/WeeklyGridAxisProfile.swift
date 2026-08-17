//
//  WeeklyGridAxisProfile.swift
//  Holo
//
//  周历整周共享的弹性时间轴：同一小时在七天内保持同高、同坐标。
//

import CoreGraphics
import Foundation

struct WeeklyGridAxisProfile {
    struct HourSegment: Identifiable, Equatable {
        let hour: Int
        let top: CGFloat
        let height: CGFloat

        var id: Int { hour }
    }

    static let baseHourHeight: CGFloat = 42
    static let twoEventHeight: CGFloat = 57
    static let threeEventHeight: CGFloat = 84
    static let fourEventHeight: CGFloat = 111
    static let overflowHourHeight: CGFloat = 131

    let startHour: Int
    let endHour: Int
    let segments: [HourSegment]
    let totalHeight: CGFloat

    /// eventCountsByDay 的每个元素代表一天，字典 key 为小时、value 为该小时事件数。
    /// scale 为双指缩放倍率（1 = 默认分档高度），整条时间轴等比缩放。
    static func make(eventCountsByDay: [[Int: Int]],
                     startHour: Int,
                     endHour: Int,
                     scale: CGFloat = 1) -> WeeklyGridAxisProfile {
        precondition(startHour <= endHour, "周历时间轴起始小时不能晚于结束小时")

        var top: CGFloat = 0
        var segments: [HourSegment] = []

        for hour in startHour...endHour {
            let maximumCount = eventByDayCount(eventCountsByDay, hour: hour)
            let height = snapToHalfPoint(height(forEventCount: maximumCount) * scale)
            segments.append(HourSegment(hour: hour, top: top, height: height))
            top += height
        }

        return WeeklyGridAxisProfile(
            startHour: startHour,
            endHour: endHour,
            segments: segments,
            totalHeight: top
        )
    }

    func height(for hour: Int) -> CGFloat {
        segments.first(where: { $0.hour == hour })?.height ?? Self.baseHourHeight
    }

    func top(for hour: Int) -> CGFloat {
        if hour <= startHour { return 0 }
        if hour > endHour { return totalHeight }
        return segments.first(where: { $0.hour == hour })?.top ?? totalHeight
    }

    func yPosition(hour: Int, minute: Int) -> CGFloat {
        let clampedMinute = min(59, max(0, minute))
        return top(for: hour) + CGFloat(clampedMinute) / 60 * height(for: hour)
    }

    private static func height(forEventCount count: Int) -> CGFloat {
        switch count {
        case ...1: return baseHourHeight
        case 2: return twoEventHeight
        case 3: return threeEventHeight
        case 4: return fourEventHeight
        default: return overflowHourHeight
        }
    }

    private static func eventByDayCount(_ eventCountsByDay: [[Int: Int]], hour: Int) -> Int {
        eventCountsByDay.map { $0[hour] ?? 0 }.max() ?? 0
    }

    /// 圆整到 0.5pt，避免缩放过程中出现亚像素高度导致刻度线闪烁
    private static func snapToHalfPoint(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}
