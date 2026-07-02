//
//  ThoughtOrganizeActionChip.swift
//  Holo
//
//  想法模块「自动整理」动作芯片
//  触发批量 AI 打标签，紫色 AI 专属色，区别于普通筛选 chip（动作触发器，非筛选器）
//

import SwiftUI

// MARK: - ThoughtOrganizeActionChip

/// 「自动整理」动作芯片
/// 与 HoloFilterChip 区别：它是动作触发器（点击启动批量整理），带 sparkles + AI 角标 + 待整理数徽章，紫色异色
struct ThoughtOrganizeActionChip: View {

    /// 待整理数量（>0 时显示徽章）
    let pendingCount: Int

    /// 是否正在整理中（改变文案与高亮态）
    var isOrganizing: Bool = false

    /// 点击触发
    let action: () -> Void

    private var badgeText: String {
        pendingCount > 99 ? "99+" : "\(pendingCount)"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                // sparkles 图标（项目 AI 统一图标）
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoAI)

                // 文案
                Text(isOrganizing ? "整理中" : "自动整理")
                    .font(.holoCaption)
                    .foregroundColor(.holoAI)

                // AI 角标
                Text("AI")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.holoAI.opacity(0.7))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.holoAI.opacity(0.12))
                    .cornerRadius(3)

                // 待整理数量徽章（整理中或无待整理时隐藏）
                if !isOrganizing && pendingCount > 0 {
                    Text(badgeText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(minWidth: 18)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.holoAI)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(width: 132)
            .background(
                Capsule()
                    .fill(Color.holoAI.opacity(isOrganizing ? 0.14 : 0.08))
            )
            .overlay(
                Capsule()
                    .stroke(Color.holoAI.opacity(isOrganizing ? 0.6 : 0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 8) {
        ThoughtOrganizeActionChip(pendingCount: 12) {}
        ThoughtOrganizeActionChip(pendingCount: 0) {}
        ThoughtOrganizeActionChip(pendingCount: 3, isOrganizing: true) {}
    }
    .padding()
    .background(Color.holoBackground)
}
