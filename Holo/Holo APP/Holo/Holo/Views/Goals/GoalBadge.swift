//
//  GoalBadge.swift
//  Holo
//
//  目标归属标签（胶囊样式）
//  用在任务行/习惯行/今日看板行，显示"属于哪个目标"。
//  配色按目标领域区分，全部使用 holoChart 色板。
//

import SwiftUI

extension GoalDomain {
    /// 标签配色，全部来自已验证存在的 holoChart1-12 色板（DesignSystem.swift）
    var badgeColor: Color {
        switch self {
        case .learning: return .holoChart1   // 蓝 #3B82F6
        case .health:   return .holoChart3   // 绿 #22C55E
        case .career:   return .holoChart8   // 黄 #EAB308
        case .finance:  return .holoChart2   // 橙 #F97316
        case .life:     return .holoChart5   // 紫 #8B5CF6
        case .project:  return .holoChart6   // 青 #14B8A6
        case .other:    return .holoPurple   // 浅紫 #C084FC
        }
    }
}

struct GoalBadge: View {
    let goal: Goal
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: goal.goalDomain.icon)
                .font(.system(size: 9, weight: .medium))
            Text(compact ? goal.goalDomain.displayName : goal.title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(goal.goalDomain.badgeColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(goal.goalDomain.badgeColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
