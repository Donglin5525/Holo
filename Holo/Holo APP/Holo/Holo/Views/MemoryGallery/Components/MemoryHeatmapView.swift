//
//  MemoryHeatmapView.swift
//  Holo
//
//  最近 13 周主动活跃热力图
//

import SwiftUI

private enum MemoryHeatmapPalette {
    static func color(forLevel level: Int, colorScheme: ColorScheme) -> Color {
        Color(hex: hex(forLevel: level, colorScheme: colorScheme))
    }

    private static func hex(forLevel level: Int, colorScheme: ColorScheme) -> String {
        switch colorScheme {
        case .dark:
            switch level {
            case ...1: return "#302925"
            case 2:    return "#4A3028"
            case 3:    return "#663A2C"
            case 4:    return "#84462F"
            default:   return "#A95634"
            }
        default:
            switch level {
            case ...1: return "#F5F2ED"
            case 2:    return "#FFD6C7"
            case 3:    return "#FFB499"
            case 4:    return "#FF9B7A"
            default:   return "#FF8C66"
            }
        }
    }
}

struct MemoryHeatmapView: View {
    let data: [Date: Int]
    let selectedDate: Date?
    let onSelectDate: (Date) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    private let cellSize: CGFloat = 16
    private let cellSpacing: CGFloat = 3
    private let hitSize: CGFloat = 22

    private var weekStarts: [Date] {
        let currentWeekStart = Date().startOfDay.startOfWeek
        return (0..<13).map { offset in
            currentWeekStart.addingWeeks(offset - 12)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            header
            monthHeader

            HStack(alignment: .top, spacing: 6) {
                weekdayLabels
                heatmapGrid
            }

            legend
        }
        .padding(HoloSpacing.lg)
        .background(
            LinearGradient(
                colors: [
                    Color.holoCardBackground,
                    Color.holoPrimary.opacity(colorScheme == .dark ? 0.12 : 0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder.opacity(0.65), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: HoloRadius.sm)
                    .fill(Color.holoPrimary.opacity(0.12))
                    .frame(width: 38, height: 38)

                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoPrimary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("活跃热力图")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                Text("最近 13 周 · \(recordedDayCount) 天有记录")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer(minLength: 0)
        }
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
                        .stroke(borderColor(count: count, isSelected: isSelected), lineWidth: isSelected ? 2.5 : 1)
                )
                .shadow(color: shadowColor(count: count), radius: count > 0 ? 3 : 0, x: 0, y: 1)
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
        MemoryHeatmapPalette.color(forLevel: level(for: count), colorScheme: colorScheme)
    }

    private func borderColor(count: Int, isSelected: Bool) -> Color {
        if isSelected {
            return .holoTextPrimary
        }
        return count == 0
            ? .holoBorder.opacity(0.85)
            : .white.opacity(colorScheme == .dark ? 0.1 : 0.28)
    }

    private func shadowColor(count: Int) -> Color {
        level(for: count) == 5 ? color(for: count).opacity(colorScheme == .dark ? 0.2 : 0.1) : .clear
    }

    private var legend: some View {
        HStack(spacing: HoloSpacing.xs) {
            Text("少")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder)

            ForEach(1...5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 3)
                    .fill(colorForLegendLevel(level))
                    .frame(width: 16, height: 16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(level == 1 ? Color.holoBorder.opacity(0.85) : Color.clear, lineWidth: 1)
                    )
            }

            Text("多")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder)

            Spacer()
        }
    }

    private func colorForLegendLevel(_ level: Int) -> Color {
        switch level {
        case 1: return color(for: 1)
        case 2: return color(for: 2)
        case 3: return color(for: 3)
        case 4: return color(for: 6)
        default: return color(for: 10)
        }
    }

    private var recordedDayCount: Int {
        data.filter { $0.value > 0 }.count
    }

    private func level(for count: Int) -> Int {
        switch count {
        case 0...1:
            return 1
        case 2...3:
            return 2
        case 4...5:
            return 3
        case 6...9:
            return 4
        default:
            return 5
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
