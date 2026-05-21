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
            HStack(alignment: .top, spacing: HoloSpacing.md) {
                Image(systemName: "target")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 40, height: 40)
                    .background(Color.holoPrimary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    Text("目标已创建")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)

                    Text(data.title)
                        .font(.holoBody)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    HStack(spacing: 6) {
                        Text(data.summary)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                        Spacer(minLength: 0)
                        Text("查看")
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoPrimary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                    }
                }
            }
            .padding(HoloSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(Color.holoBorder, lineWidth: 1)
            )
            .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
        }
        .buttonStyle(CardButtonStyle())
    }
}
