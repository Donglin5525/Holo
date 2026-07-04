//
//  CalendarFilterBar.swift
//  Holo
//
//  日历模块筛选栏（P2）：全部 + 4 模块 chip，单选
//

import SwiftUI

struct CalendarFilterBar: View {
    @Binding var moduleFilter: CalendarModule?

    /// P1/P2 阶段可筛的模块（健康 P3）
    private let modules: [CalendarModule] = [.finance, .habit, .todo, .thought]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HoloSpacing.xs) {
                chip(label: "全部", color: .holoTextSecondary, icon: nil,
                     isSelected: moduleFilter == nil) {
                    moduleFilter = nil
                }
                ForEach(modules, id: \.self) { module in
                    chip(label: module.displayName, color: module.color, icon: module.iconName,
                         isSelected: moduleFilter == module) {
                        moduleFilter = module
                    }
                }
            }
            .padding(.horizontal, HoloSpacing.md)
        }
    }

    private func chip(label: String,
                      color: Color,
                      icon: String?,
                      isSelected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(label)
                    .font(.holoLabel)
            }
            .foregroundColor(isSelected ? .white : color)
            .padding(.horizontal, HoloSpacing.sm)
            .padding(.vertical, 5)
            .background(isSelected ? color : color.opacity(0.10))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
