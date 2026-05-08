//
//  HabitIcon+View.swift
//  Holo
//
//  习惯图标统一渲染协议
//  集中处理 SF Symbol 和自定义 Asset Catalog 图标的渲染分支
//

import SwiftUI

// MARK: - 协议定义

protocol HabitIconRenderable {
    var icon: String { get }
    var isCustomIcon: Bool { get }
}

// MARK: - 统一渲染方法

extension HabitIconRenderable {
    @ViewBuilder
    func iconImage(size: CGFloat) -> some View {
        if isCustomIcon {
            Image(icon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
        }
    }
}

// MARK: - 协议实现

extension Habit: HabitIconRenderable {}

extension HabitDetailSnapshot: HabitIconRenderable {}

extension HabitStatsDisplayItem: HabitIconRenderable {}

extension HabitStatsItem: HabitIconRenderable {}
