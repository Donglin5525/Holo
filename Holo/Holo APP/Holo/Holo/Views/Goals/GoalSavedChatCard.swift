//
//  GoalSavedChatCard.swift
//  Holo
//
//  Chat 中目标保存完成后的入口卡片
//

import SwiftUI

struct GoalSavedChatCardData: Equatable, Sendable {
    let goalId: UUID
    let title: String
    let taskCount: Int
    let habitCount: Int
    let metricSummary: String?

    nonisolated init?(dictionary: [String: String]?) {
        guard let dictionary,
              let idText = dictionary["goalId"],
              let goalId = UUID(uuidString: idText),
              let title = dictionary["goalTitle"],
              !title.isEmpty else {
            return nil
        }

        self.goalId = goalId
        self.title = title
        self.taskCount = Int(dictionary["createdTaskCount"] ?? "") ?? 0
        self.habitCount = Int(dictionary["createdHabitCount"] ?? "") ?? 0
        let rawMetric = dictionary["metricSummary"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.metricSummary = (rawMetric?.isEmpty == false) ? rawMetric : nil
    }

    var summary: String {
        if let metricSummary {
            return "\(metricSummary) · \(taskCount) 个任务 · \(habitCount) 个习惯"
        }
        return "\(taskCount) 个任务 · \(habitCount) 个习惯"
    }
}

struct GoalSavedChatCard: View {

    let data: GoalSavedChatCardData
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            onTap?()
        } label: {
            ChatCardView {
                CardHeaderView(
                    icon: "target",
                    title: String(localized: "目标已创建"),
                    subtitle: data.title
                )

                if let metricSummary = data.metricSummary {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                        Text(metricSummary)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.holoToolText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.holoPrimary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    HoloAIMetricTile(label: String(localized: "任务"), value: "\(data.taskCount)")
                    HoloAIMetricTile(label: String(localized: "习惯"), value: "\(data.habitCount)")
                }

                HStack(spacing: 6) {
                    Text("查看目标")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                }
            }
        }
        .buttonStyle(CardButtonStyle())
    }
}
