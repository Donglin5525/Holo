//
//  MemoryTimeChapterPresentation.swift
//  Holo
//
//  记忆长廊三档共用的「时间章节」展示语义。
//  只负责把时间范围与记录证据转成用户能读懂的标题，不承载 SwiftUI 状态。
//

import Foundation

enum MemoryTimeChapterScale: Equatable {
    case day
    case week
    case month
}

struct MemoryTimeChapterPresentation: Equatable {
    let primaryText: String
    let title: String
    let evidence: String
    let currentBadge: String?
    let accessibilityLabel: String

    static func make(
        scale: MemoryTimeChapterScale,
        focusedDate: Date,
        periodStart: Date,
        periodEnd: Date,
        eventCount: Int,
        momentCount: Int,
        activeDayCount: Int,
        firstEventDate: Date?,
        lastEventDate: Date?,
        isCurrentPeriod: Bool,
        calendar inputCalendar: Calendar = .current
    ) -> MemoryTimeChapterPresentation {
        var calendar = inputCalendar
        calendar.firstWeekday = 2

        let primaryText: String
        let title: String
        let emptyEvidence: String
        let currentBadge: String?
        let accessibilityLabel: String

        switch scale {
        case .day:
            primaryText = "\(calendar.component(.day, from: focusedDate))"
            title = monthWeekdayFormatter(calendar: calendar).string(from: focusedDate)
            emptyEvidence = "这一天很安静"
            currentBadge = isCurrentPeriod ? "今天" : nil
            accessibilityLabel = fullDayFormatter(calendar: calendar).string(from: focusedDate)

        case .week:
            let inclusiveEnd = periodEnd.addingTimeInterval(-1)
            primaryText = "\(calendar.component(.day, from: periodStart))—\(calendar.component(.day, from: inclusiveEnd))"
            let startMonth = calendar.component(.month, from: periodStart)
            let endMonth = calendar.component(.month, from: inclusiveEnd)
            let monthText = startMonth == endMonth ? "\(startMonth)月" : "\(startMonth)月—\(endMonth)月"
            title = "\(monthText) · 第\(calendar.component(.weekOfYear, from: focusedDate))周"
            emptyEvidence = "这一周还没有留下记录"
            currentBadge = isCurrentPeriod ? "本周" : nil
            accessibilityLabel = "\(fullDayFormatter(calendar: calendar).string(from: periodStart))至\(fullDayFormatter(calendar: calendar).string(from: inclusiveEnd))"

        case .month:
            primaryText = "\(calendar.component(.month, from: focusedDate))月"
            title = "\(calendar.component(.year, from: focusedDate))年"
            emptyEvidence = "这个月还没有留下记录"
            currentBadge = isCurrentPeriod ? "本月" : nil
            accessibilityLabel = yearMonthFormatter(calendar: calendar).string(from: focusedDate)
        }

        let evidence: String
        if eventCount == 0 {
            evidence = emptyEvidence
        } else if scale == .day,
                  let firstEventDate,
                  let lastEventDate {
            evidence = "\(momentCount) 个记忆时刻 · \(timeFormatter(calendar: calendar).string(from: firstEventDate))—\(timeFormatter(calendar: calendar).string(from: lastEventDate))"
        } else {
            evidence = "\(activeDayCount) 天有记录 · \(momentCount) 个记忆时刻"
        }

        return MemoryTimeChapterPresentation(
            primaryText: primaryText,
            title: title,
            evidence: evidence,
            currentBadge: currentBadge,
            accessibilityLabel: accessibilityLabel
        )
    }

    private static func monthWeekdayFormatter(calendar: Calendar) -> DateFormatter {
        formatter(calendar: calendar, format: "M月 · EEEE")
    }

    private static func fullDayFormatter(calendar: Calendar) -> DateFormatter {
        formatter(calendar: calendar, format: "yyyy年M月d日 EEEE")
    }

    private static func yearMonthFormatter(calendar: Calendar) -> DateFormatter {
        formatter(calendar: calendar, format: "yyyy年M月")
    }

    private static func timeFormatter(calendar: Calendar) -> DateFormatter {
        formatter(calendar: calendar, format: "HH:mm")
    }

    private static func formatter(calendar: Calendar, format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }
}
