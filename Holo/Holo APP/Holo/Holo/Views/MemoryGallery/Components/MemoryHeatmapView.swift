//
//  MemoryHeatmapView.swift
//  Holo
//
//  最近 13 周主动活跃热力图
//

import SwiftUI

struct MemoryHeatmapView: View {
    let data: [Date: Int]
    let selectedDate: Date?
    let onSelectDate: (Date) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    private let cellSize: CGFloat = 14
    private let cellSpacing: CGFloat = 3
    private let hitSize: CGFloat = 22

    private var weekStarts: [Date] {
        let currentWeekStart = Date().startOfDay.startOfWeek
        return (0..<13).map { offset in
            currentWeekStart.addingWeeks(offset - 12)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            monthHeader

            HStack(alignment: .top, spacing: 6) {
                weekdayLabels
                heatmapGrid
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    private var monthHeader: some View {
        HStack(spacing: cellSpacing) {
            Color.clear
                .frame(width: 18, height: 12)

            ForEach(Array(weekStarts.enumerated()), id: \.offset) { index, weekStart in
                Text(monthLabel(for: weekStart, index: index))
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: hitSize, height: 12, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var weekdayLabels: some View {
        VStack(spacing: cellSpacing) {
            ForEach(weekdays, id: \.self) { weekday in
                Text(weekday)
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 18, height: hitSize, alignment: .center)
            }
        }
    }

    private var heatmapGrid: some View {
        HStack(spacing: cellSpacing) {
            ForEach(weekStarts, id: \.self) { weekStart in
                VStack(spacing: cellSpacing) {
                    ForEach(0..<7, id: \.self) { dayOffset in
                        let date = weekStart.addingDays(dayOffset).startOfDay
                        heatmapCell(for: date)
                    }
                }
            }
        }
    }

    private func heatmapCell(for date: Date) -> some View {
        let count = data[date.startOfDay] ?? 0
        let isSelected = selectedDate?.isSameDay(as: date) == true

        return Button {
            onSelectDate(date)
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(color(for: count))
                .frame(width: cellSize, height: cellSize)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(borderColor(count: count, isSelected: isSelected), lineWidth: isSelected ? 2 : 1)
                )
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(date > Date().startOfDay)
        .opacity(date > Date().startOfDay ? 0.35 : 1)
    }

    private func monthLabel(for weekStart: Date, index: Int) -> String {
        let calendar = Calendar.current
        if index == 0 || calendar.component(.month, from: weekStart) != calendar.component(.month, from: weekStarts[index - 1]) {
            return "\(calendar.component(.month, from: weekStart))月"
        }
        return ""
    }

    private func color(for count: Int) -> Color {
        switch level(for: count) {
        case 0:
            return .holoCardBackground
        case 1:
            return colorScheme == .dark
                ? (Color(hex: "#78350F") ?? .orange).opacity(0.4)
                : (Color(hex: "#FEF3C7") ?? .yellow)
        case 2:
            return colorScheme == .dark
                ? (Color(hex: "#92400E") ?? .orange).opacity(0.6)
                : (Color(hex: "#FBBF24") ?? .orange)
        case 3:
            return colorScheme == .dark
                ? (Color(hex: "#EA580C") ?? .orange).opacity(0.8)
                : (Color(hex: "#F97316") ?? .orange)
        default:
            return Color(hex: "#F46D38") ?? .holoPrimary
        }
    }

    private func borderColor(count: Int, isSelected: Bool) -> Color {
        if isSelected {
            return .holoPrimary
        }
        return count == 0 ? .holoBorder : .clear
    }

    private func level(for count: Int) -> Int {
        switch count {
        case 0:
            return 0
        case 1...2:
            return 1
        case 3...5:
            return 2
        case 6...10:
            return 3
        default:
            return 4
        }
    }
}

#Preview {
    MemoryHeatmapView(
        data: [
            Date().startOfDay: 5,
            Date().startOfDay.addingDays(-1): 2,
            Date().startOfDay.addingDays(-3): 12
        ],
        selectedDate: Date().startOfDay,
        onSelectDate: { _ in }
    )
    .padding()
    .background(Color.holoBackground)
}
