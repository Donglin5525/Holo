//
//  HoloFilterChip.swift
//  Holo
//
//  通用筛选芯片组件
//  用于 Tab 栏筛选、周期选择等场景
//

import SwiftUI

// MARK: - HoloFilterChip

/// 通用筛选芯片组件
/// 支持带图标或不带图标两种模式
struct HoloFilterChip: View {
    let title: String
    var icon: String? = nil
    var iconColor: Color? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(iconColor != nil && !isSelected ? iconColor : nil)
                }
                Text(title)
                    .font(.holoCaption)
            }
            .foregroundColor(isSelected ? .white : .holoTextSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? (iconColor ?? Color.holoPrimary) : Color.holoCardBackground)
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.clear : Color.holoDivider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview("Filter Chips") {
    VStack(spacing: 20) {
        // 带图标
        HStack(spacing: 8) {
            HoloFilterChip(title: "全部", icon: "tray.full.fill", isSelected: true) {}
            HoloFilterChip(title: "今日", icon: "sun.max.fill", isSelected: false) {}
            HoloFilterChip(title: "已过期", icon: "exclamationmark.triangle.fill", isSelected: false) {}
        }

        // 不带图标
        HStack(spacing: 8) {
            HoloFilterChip(title: "本周", isSelected: true) {}
            HoloFilterChip(title: "本月", isSelected: false) {}
            HoloFilterChip(title: "本年", isSelected: false) {}
        }
    }
    .padding()
    .background(Color.holoBackground)
}
