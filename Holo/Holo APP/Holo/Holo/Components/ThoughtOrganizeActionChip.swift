//
//  ThoughtOrganizeActionChip.swift
//  Holo
//
//  想法模块 AI 动作芯片
//  有未处理笔记时触发批量打标签；没有未处理笔记时触发主题归纳。
//

import SwiftUI

// MARK: - ThoughtOrganizeActionChip

/// AI 整理动作芯片
/// 与 HoloFilterChip 区别：它是动作触发器；主交互使用品牌橙，紫色仅标记 AI 来源。
struct ThoughtOrganizeActionChip: View {

    /// 待整理数量（>0 时显示徽章）
    let pendingCount: Int

    /// 是否正在整理中（改变文案与高亮态）
    var isOrganizing: Bool = false

    /// 点击触发
    let action: () -> Void

    private var title: String {
        if isOrganizing { return "整理中" }
        return pendingCount > 0 ? "整理笔记" : "归纳主题"
    }

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
                Text(title)
                    .font(.holoCaption)
                    .foregroundColor(.holoPrimary)

                // AI 角标
                Text("AI")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.holoBackground)
                    .cornerRadius(3)

                // 待整理数量徽章（整理中或无待整理时隐藏）
                if !isOrganizing && pendingCount > 0 {
                    Text(badgeText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(minWidth: 18)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.holoPrimary)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(width: 132)
            .background(
                Capsule()
                    .fill(Color.holoPrimary.opacity(isOrganizing ? 0.12 : 0.06))
            )
            .overlay(
                Capsule()
                    .stroke(Color.holoPrimary.opacity(isOrganizing ? 0.55 : 0.35), lineWidth: 1)
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
