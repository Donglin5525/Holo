//
//  HabitStatsExpandableCardView.swift
//  Holo
//
//  统计页可展开习惯卡片
//  折叠态显示周视图，展开态显示月历矩阵
//  单开规则：同一时间只有一个卡片展开
//

import SwiftUI

struct HabitStatsExpandableCardView: View {
    let item: HabitStatsDisplayItem
    let isExpanded: Bool
    let onTap: () -> Void

    private var accent: Color {
        Color(hex: item.habitColorHex) ?? .holoPrimary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            header

            if isExpanded {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                collapsedContent
                    .transition(.opacity)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.24)) {
                onTap()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: item.icon)
                .font(.system(size: 18))
                .foregroundColor(accent)
                .frame(width: 32, height: 32)
                .background(accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                HStack(spacing: 6) {
                    typeTag
                    summaryText
                }
            }

            Spacer()

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.holoTextSecondary)
        }
    }

    private var typeTag: some View {
        Text(typeName)
            .font(.holoTinyLabel)
            .foregroundColor(accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(accent.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var typeName: String {
        switch item.type {
        case .checkIn: return "打卡"
        case .count: return "计数"
        case .measure: return "测量"
        }
    }

    private var summaryText: some View {
        Text(summaryDescription)
            .font(.holoTinyLabel)
            .foregroundColor(.holoTextSecondary)
    }

    private var summaryDescription: String {
        switch item.summary {
        case .checkIn(let completedDays, let streak):
            return "完成\(completedDays)天 · 连续\(streak)天"
        case .count(let recordedDays, let totalCountText):
            return "完成\(recordedDays)天 · 累计\(totalCountText)"
        case .measure(let recordedDays, _):
            return "记录\(recordedDays)天"
        }
    }

    // MARK: - Collapsed Content

    private var collapsedContent: some View {
        VStack(spacing: HoloSpacing.sm) {
            HabitWeekStripView(week: item.collapsedWeek, accentColor: accent)

            if item.collapsedWeek.days.allSatisfy({ !$0.hasRecord }) {
                Text("本周暂无记录")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(spacing: HoloSpacing.md) {
            HabitMonthGridView(month: item.month, accentColor: accent)

            expandedSummary
        }
    }

    private var expandedSummary: some View {
        HStack(spacing: HoloSpacing.md) {
            switch item.summary {
            case .checkIn(let completedDays, let streak):
                expandedStat(label: "完成天数", value: "\(completedDays)")
                expandedStat(label: "连续天数", value: "\(streak)")
            case .count(let recordedDays, let totalCountText):
                expandedStat(label: "完成天数", value: "\(recordedDays)")
                expandedStat(label: "累计", value: totalCountText)
            case .measure(let recordedDays, let averageValueText):
                expandedStat(label: "记录天数", value: "\(recordedDays)")
                expandedStat(label: "平均", value: averageValueText)
            }
        }
    }

    private func expandedStat(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
            Text(label)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.holoBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
    }
}

// MARK: - Preview

#Preview("Collapsed") {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())

    let week = HabitStatsWeekSlice(
        weekStart: today,
        days: (0..<7).map { i in
            let date = calendar.date(byAdding: .day, value: i, to: today)!
            return HabitStatsDayCell(
                date: date,
                dayNumber: i + 1,
                isInCurrentMonth: true,
                isToday: i == 0,
                hasRecord: i % 2 == 0
            )
        }
    )

    HabitStatsExpandableCardView(
        item: HabitStatsDisplayItem(
            habitId: UUID(),
            name: "健身",
            icon: "figure.strengthtraining.traditional",
            habitColorHex: "#F46D38",
            type: .count,
            summary: .count(recordedDays: 12, totalCountText: "12次"),
            collapsedWeek: week,
            allWeeks: [],
            month: HabitStatsMonthSection(monthStart: today, weekdaySymbols: calendar.shortWeekdaySymbols, rows: [])
        ),
        isExpanded: false,
        onTap: {}
    )
    .padding()
    .background(Color.holoBackground)
}

#Preview("Expanded") {
    let calendar = Calendar.current
    let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!

    let sampleRow: [HabitStatsDayCell] = (1..<8).map { day in
        HabitStatsDayCell(
            date: calendar.date(byAdding: .day, value: day, to: monthStart)!,
            dayNumber: day,
            isInCurrentMonth: true,
            isToday: false,
            hasRecord: day % 3 == 0
        )
    }

    HabitStatsExpandableCardView(
        item: HabitStatsDisplayItem(
            habitId: UUID(),
            name: "体重",
            icon: "scalemass",
            habitColorHex: "#3B82F6",
            type: .measure,
            summary: .measure(recordedDays: 18, averageValueText: "58.2kg"),
            collapsedWeek: HabitStatsWeekSlice(weekStart: monthStart, days: sampleRow),
            allWeeks: [],
            month: HabitStatsMonthSection(
                monthStart: monthStart,
                weekdaySymbols: calendar.shortWeekdaySymbols,
                rows: [sampleRow, sampleRow, sampleRow, sampleRow]
            )
        ),
        isExpanded: true,
        onTap: {}
    )
    .padding()
    .background(Color.holoBackground)
}
