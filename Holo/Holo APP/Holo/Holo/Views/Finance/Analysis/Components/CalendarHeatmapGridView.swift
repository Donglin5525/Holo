//
//  CalendarHeatmapGridView.swift
//  Holo
//
//  共享日历热力图网格（全项目标准件，图表规范 §4.5 / 2026-10-07）：
//  输入按日期升序的连续逐日计数（首日须为周一、共 weeks×7 天），
//  GitHub 式布局（行=周几、列=周），色阶唯一来源 Color.holoHeatmapColor，
//  组件内禁止硬编码 hex。未来日降透明；点按回调选中日。
//

import SwiftUI

struct CalendarHeatmapGridView: View {

    nonisolated struct Day: Identifiable, Equatable, Sendable {
        let date: Date
        let count: Int
        let isFuture: Bool
        var id: Date { date }
    }

    let days: [Day]
    /// 每行左侧星期标签（7 个，空串=该行不标）；少于 7 个则不显示标签列
    var weekdayLabels: [String] = []
    /// 顶部月轴：每周列首日所在月变化时标「M月」
    var showsMonthAxis: Bool = false
    /// 色阶语义：warm=活跃（品牌橙）cool=记录（信息蓝）
    var palette: Color.HoloHeatmapPalette = .warm
    var onTapDay: ((Day) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var weeks: Int { max(days.count / 7, 1) }
    private var hasLabelColumn: Bool { weekdayLabels.count == 7 }
    private var maxCount: Int { max(days.map(\.count).max() ?? 0, 1) }

    private func day(atWeek week: Int, weekday: Int) -> Day? {
        let index = week * 7 + weekday
        return days.indices.contains(index) ? days[index] : nil
    }

    /// 等级 0=空档，1...5 由浅到深（相对本期最大值折算，1 件起即有色）
    private func level(for day: Day) -> Int {
        guard day.count > 0 else { return 0 }
        return min(5, max(1, Int(ceil(Double(day.count) / Double(maxCount) * 5))))
    }

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("M月d日")
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsMonthAxis {
                monthAxis
            }
            VStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { weekday in
                    HStack(spacing: 3) {
                        if hasLabelColumn {
                            Text(weekdayLabels[weekday])
                                .font(.system(size: 9))
                                .foregroundColor(.holoTextPlaceholder)
                                .frame(width: 14, alignment: .trailing)
                        }
                        ForEach(0..<weeks, id: \.self) { week in
                            if let day = day(atWeek: week, weekday: weekday) {
                                cell(day)
                            } else {
                                Color.clear.aspectRatio(1, contentMode: .fit)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 单元格

    private func cell(_ day: Day) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.holoHeatmapColor(level: level(for: day), palette: palette, colorScheme: colorScheme))
            .aspectRatio(1, contentMode: .fit)
            .opacity(day.isFuture ? 0.35 : 1)
            .onTapGesture { onTapDay?(day) }
            .accessibilityLabel("\(dayFormatter.string(from: day.date)) \(String(localized: "完成 \(day.count) 件"))")
            .accessibilityHidden(day.isFuture)
    }

    // MARK: - 月轴

    /// 与网格同构的顶部行：14pt 标签列占位 + 每周列一格，月变化的那周标「M月」
    private var monthAxis: some View {
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "zh_CN")
        monthFormatter.setLocalizedDateFormatFromTemplate("M月")
        let labels: [String?] = (0..<weeks).map { week in
            guard let firstDayOfWeek = day(atWeek: week, weekday: 0)?.date else { return nil }
            let month = calendarComponent(.month, of: firstDayOfWeek)
            if week == 0 { return monthFormatter.string(from: firstDayOfWeek) }
            guard let prevFirst = day(atWeek: week - 1, weekday: 0)?.date else { return nil }
            return month != calendarComponent(.month, of: prevFirst)
                ? monthFormatter.string(from: firstDayOfWeek)
                : nil
        }
        return HStack(spacing: 3) {
            if hasLabelColumn {
                Color.clear.frame(width: 14, height: 10)
            }
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(label ?? "")
                    .font(.system(size: 9))
                    .foregroundColor(.holoTextPlaceholder)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }
        }
    }

    private func calendarComponent(_ component: Calendar.Component, of date: Date) -> Int {
        Self.monthCalendar.component(component, from: date)
    }

    /// 月轴只看自然月，与周起始约定无关
    private static let monthCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()
}
