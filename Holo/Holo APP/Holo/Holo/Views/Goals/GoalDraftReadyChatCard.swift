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
            VStack(alignment: .leading, spacing: 10) {
                // 标题行
                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .font(.system(size: 16))
                        .foregroundColor(.holoPrimary)
                    Text("目标计划已生成")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                }

                // 目标标题
                Text(draft.title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                // 摘要
                Text(draft.cardSummary)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                // 提示行
                HStack(spacing: 4) {
                    Text("点击查看详细计划")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary.opacity(0.6))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoTextSecondary.opacity(0.6))
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
