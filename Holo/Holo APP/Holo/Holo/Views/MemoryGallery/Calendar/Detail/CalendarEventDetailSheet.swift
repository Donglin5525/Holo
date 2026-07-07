//
//  CalendarEventDetailSheet.swift
//  Holo
//
//  日历事件只读详情（按 CalendarEvent 展示模块/标题/副信息/时间）
//  P3：想法事件额外展示「相关观点」（经 Thought.topics 间接体现观点维度）
//
//  「在 X 模块打开」跳原模块编辑页：需 deep link / dismiss 画廊后路由，
//  受画廊 fullScreenCover 隔离暂未接入，留 TODO（originID 已具备回查能力）。
//

import SwiftUI

struct CalendarEventGroup: Identifiable {
    let id = UUID()
    let events: [CalendarEvent]

    var title: String {
        guard let first = events.first else { return "记录明细" }
        let hour = Calendar.current.component(.hour, from: first.date)
        let moduleCount = Set(events.map(\.module)).count
        if moduleCount == 1, let module = events.first?.module {
            return "\(hour):00 \(module.displayName) +\(events.count)"
        }
        return "\(hour):00 记录 +\(events.count)"
    }
}

struct CalendarEventDetailSheet: View {
    let event: CalendarEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    moduleHeader
                    infoCard
                    if let topics = event.relatedTopics, !topics.isEmpty {
                        topicsCard(topics)
                    }
                }
                .padding(HoloSpacing.md)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: - 模块标识

    private var moduleHeader: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: event.module.iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(event.module.color)
                .frame(width: 36, height: 36)
                .background(event.module.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            Text(event.module.displayName)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
            Spacer()
        }
    }

    // MARK: - 信息卡

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(event.title)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            if let detail = event.detail {
                Text(detail)
                    .font(.holoBody)
                    .foregroundColor(event.module.color)
            }

            Divider()

            HStack {
                Text("时间")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Text(fullDateTime)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPrimary)
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

    // MARK: - P3 相关观点（仅想法事件）

    private func topicsCard(_ topics: [String]) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: 5) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoPurple)
                Text("相关观点")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HoloSpacing.xs) {
                    ForEach(topics, id: \.self) { topic in
                        Text(topic)
                            .font(.holoLabel)
                            .foregroundColor(.holoPurple)
                            .padding(.horizontal, HoloSpacing.sm)
                            .padding(.vertical, 4)
                            .background(Color.holoPurple.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
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

    private var fullDateTime: String {
        Self.formatter.string(from: event.date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

struct CalendarEventGroupDetailSheet: View {
    let group: CalendarEventGroup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    ForEach(sortedEvents) { event in
                        eventRow(event)
                    }
                }
                .padding(HoloSpacing.md)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle(group.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var sortedEvents: [CalendarEvent] {
        group.events.sorted { $0.date < $1.date }
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Image(systemName: event.module.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(event.module.color)
                .frame(width: 28, height: 28)
                .background(event.module.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.timeText(for: event.date))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.holoTextSecondary)
                    Text(event.title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(2)
                }
                if let detail = event.detail {
                    Text(detail)
                        .font(.holoCaption)
                        .foregroundColor(event.module.color)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(HoloSpacing.sm)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.75), lineWidth: 1)
        )
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
