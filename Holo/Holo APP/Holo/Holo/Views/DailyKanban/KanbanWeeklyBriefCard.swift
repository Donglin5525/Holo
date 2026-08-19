//
//  KanbanWeeklyBriefCard.swift
//  Holo
//
//  今日看板顶部的「上周小结」卡：周一晨报通知点开时展示。
//  数据与通知文案同源（WeeklyBriefScheduler.lastWeekSummary），保证口径一致；
//  关闭当天不再出现。
//

import SwiftUI

struct KanbanWeeklyBriefCard: View {

    @AppStorage(WeeklyBriefScheduler.cardDismissedDayKey) private var dismissedDay: String = ""

    private let now: Date

    init(now: Date = Date()) {
        self.now = now
    }

    private var todayKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: now)
    }

    var isDismissedToday: Bool {
        dismissedDay == todayKey
    }

    var body: some View {
        let summary = WeeklyBriefScheduler.lastWeekSummary(weekStartsAt: now)

        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("上周小结 · 新的一周")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Button {
                    dismissedDay = todayKey
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: HoloSpacing.lg) {
                briefStat(value: "\(summary.completedTasks)", label: "完成事项")
                Divider().frame(height: 24)
                briefStat(value: "\(summary.habitDays) 天", label: "习惯打卡")
            }

            if let focus = summary.focus, !focus.isEmpty {
                Text("本周重点：\(focus)")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(2)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
    }

    private func briefStat(value: String, label: String) -> some View {
        HStack(spacing: HoloSpacing.xs) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(.holoPrimary)
            Text(label)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }
}

#Preview {
    KanbanWeeklyBriefCard()
        .padding()
        .background(Color.holoBackground)
}
