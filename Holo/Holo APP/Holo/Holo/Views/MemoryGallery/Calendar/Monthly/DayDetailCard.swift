//
//  DayDetailCard.swift
//  Holo
//
//  月历选中当天的详情卡：平铺当天全部事件，按模块分组
//

import SwiftUI

struct DayDetailCard: View {
    let day: Date
    let events: [CalendarEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            header
            ForEach(groupedModules, id: \.module.rawValue) { group in
                moduleSection(group)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    // MARK: - 衍生

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: HoloSpacing.xs) {
            Text(headerDateText)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
            if events.isEmpty {
                Text("· 无记录")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            } else {
                Text("· \(events.count) 条")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
            Spacer()
        }
    }

    /// 按 module 分组，组内按时间升序，组间按 rawValue 稳定排序
    private var groupedModules: [(module: CalendarModule, events: [CalendarEvent])] {
        Dictionary(grouping: events) { $0.module }
            .map { (module: $0.key, events: $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.module.rawValue < $1.module.rawValue }
    }

    private func moduleSection(_ group: (module: CalendarModule, events: [CalendarEvent])) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            HStack(spacing: 5) {
                Circle().fill(group.module.color).frame(width: 8, height: 8)
                Text(group.module.displayName)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Text("· \(group.events.count)")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            ForEach(group.events) { event in
                eventRow(event, module: group.module)
            }
        }
    }

    private func eventRow(_ event: CalendarEvent, module: CalendarModule) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: module.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(module.color)
                .frame(width: 24, height: 24)
                .background(module.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.timeText(for: event.date))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.holoTextSecondary)
                    Text(event.title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                }
                if let detail = event.detail {
                    Text(detail)
                        .font(.holoCaption)
                        .foregroundColor(module.color)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var headerDateText: String {
        if Calendar.current.isDateInToday(day) { return "今天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f.string(from: day)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func timeText(for date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
