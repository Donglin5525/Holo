//
//  GoalSavedChatCard.swift
//  Holo
//
//  Chat 中目标保存完成后的入口卡片
//

import SwiftUI

struct GoalSavedChatCardData: Equatable {
    let goalId: UUID
    let title: String
    let taskCount: Int
    let habitCount: Int

    init?(dictionary: [String: String]?) {
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
    }

    var summary: String {
        "\(taskCount) 个任务 · \(habitCount) 个习惯"
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
                    title: "目标已创建",
                    subtitle: data.title
                )

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    HoloAIMetricTile(label: "任务", value: "\(data.taskCount)")
                    HoloAIMetricTile(label: "习惯", value: "\(data.habitCount)")
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
