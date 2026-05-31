//
//  GoalDraftReadyChatCard.swift
//  Holo
//
//  Chat 中目标计划生成的入口卡片
//  显示草稿摘要，点击后弹出详细编辑
//

import SwiftUI

struct GoalDraftReadyChatCard: View {

    let draft: GoalDraft
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            onTap?()
        } label: {
            ChatCardView {
                CardHeaderView(
                    icon: "target",
                    title: "目标计划已生成",
                    subtitle: draft.title
                )

                HoloAIFactItem(kicker: "计划摘要", bodyText: draft.cardSummary)

                HStack(spacing: 6) {
                    Text("点击查看详细计划")
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
