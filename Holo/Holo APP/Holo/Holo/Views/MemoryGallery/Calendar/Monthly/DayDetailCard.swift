//
//  DayDetailCard.swift
//  Holo
//
//  月历选中日的「记忆时刻」预览：与日回放共用同一份聚合语义和卡片语言。
//

import SwiftUI

struct DayDetailCard: View {
    let day: Date
    let events: [CalendarEvent]
    let onSelect: (CalendarEvent) -> Void
    let onSelectGroup: ([CalendarEvent]) -> Void
    /// 切到日档连续回放该日；无记录时不显示。
    var onReplay: (() -> Void)? = nil

    private var moments: [DailyReplayMoment] {
        DailyReplayPresentation.moments(from: events)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            header

            if moments.isEmpty {
                emptyState
            } else {
                ForEach(moments) { moment in
                    HStack(alignment: .top, spacing: 10) {
                        Text(moment.timeText)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.holoTextSecondary)
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                            .padding(.top, 14)

                        DailyReplayEventCard(
                            moment: moment,
                            onSelect: onSelect,
                            onSelectGroup: onSelectGroup
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: HoloSpacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headerDateText)
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundColor(.holoTextPrimary)

                Text(moments.isEmpty ? "这一天很安静" : "\(moments.count) 个记忆时刻")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer(minLength: HoloSpacing.sm)

            if let onReplay {
                Button(action: onReplay) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("回放这一天")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 34)
                    .background(Color.holoPrimary.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                            .stroke(Color.holoPrimary.opacity(0.14), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("切换到日视图，从这一天开始连续回看")
            }
        }
        .padding(.bottom, HoloSpacing.sm)
        .overlay(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color.holoPrimary.opacity(0.55), Color.holoBorder.opacity(0.18)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
        }
    }

    private var emptyState: some View {
        Text("没有记录也构成生活的一部分。你可以选择其他日期，或回到今天继续记录。")
            .font(.system(size: 11, weight: .medium, design: .serif))
            .foregroundColor(.holoTextPlaceholder)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.holoCardBackground.opacity(0.32))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .stroke(Color.holoBorder.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var headerDateText: String {
        if Calendar.current.isDateInToday(day) { return "今天 · \(Self.weekdayFormatter.string(from: day))" }
        return Self.dateFormatter.string(from: day)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 · EEEE"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return formatter
    }()
}
