//
//  TaskQuadrantOverview.swift
//  Holo
//
//  紧凑 2×2 象限总览（方案 §4.1/§4.3/§10.1）：象限只放标题、数量和一行引导；
//  浅暖底色辅助区分、主文字高对比深色；数量只统计当前范围活动未完成任务。
//

import SwiftUI

// MARK: - 象限语义色（§10.1 原型色值，Light/Dark 双值；hex 不散写进各 View）

private func quadrantDynamicColor(light: UInt32, dark: UInt32) -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(rgb: dark)
            : UIColor(rgb: light)
    })
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension TaskQuadrant {
    /// 象限主文字色（Light 深色文字 / Dark 浅色文字，保证高对比）
    var tintColor: Color {
        switch self {
        case .doFirst: return quadrantDynamicColor(light: 0xA74532, dark: 0xF0A48E)
        case .scheduleTime: return quadrantDynamicColor(light: 0x426553, dark: 0xADD1B3)
        case .batchHandle: return quadrantDynamicColor(light: 0x876321, dark: 0xDDC07E)
        case .reviewLater: return quadrantDynamicColor(light: 0x646876, dark: 0xC4C3D4)
        case .unclassified: return Color.holoTextSecondary
        }
    }

    /// 象限浅底色
    var backgroundColor: Color {
        switch self {
        case .doFirst: return quadrantDynamicColor(light: 0xF8E9E3, dark: 0x3C2927)
        case .scheduleTime: return quadrantDynamicColor(light: 0xEAF0E8, dark: 0x28352D)
        case .batchHandle: return quadrantDynamicColor(light: 0xF7EFDD, dark: 0x383222)
        case .reviewLater: return quadrantDynamicColor(light: 0xEEEDF2, dark: 0x30303D)
        case .unclassified: return Color.holoCardBackground
        }
    }
}

// MARK: - 象限胶囊总览（2026-10-11 列表减法）

/// 零值象限不出场；有值的象限瘦成一粒胶囊（无教学句、无四色大卡）。
/// 四象限全零时整行自然隐藏。选中态 = 象限底色 + 品牌描边。
struct TaskQuadrantOverview: View {
    /// 四象限数量（不含待整理）
    let countsByQuadrant: [TaskQuadrant: Int]
    /// 当前选中的象限（nil = 全部）
    let selectedQuadrant: TaskQuadrant?
    let onQuadrantTap: (TaskQuadrant) -> Void

    private var visibleQuadrants: [(quadrant: TaskQuadrant, count: Int)] {
        TaskQuadrant.overviewOrder.compactMap { quadrant in
            let count = countsByQuadrant[quadrant] ?? 0
            return count > 0 ? (quadrant, count) : nil
        }
    }

    var body: some View {
        if !visibleQuadrants.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(visibleQuadrants, id: \.quadrant) { item in
                        quadrantChip(item.quadrant, count: item.count)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }
        }
    }

    private func quadrantChip(_ quadrant: TaskQuadrant, count: Int) -> some View {
        let isSelected = selectedQuadrant == quadrant
        return Button {
            onQuadrantTap(quadrant)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(quadrant.tintColor)
                    .frame(width: 7, height: 7)
                Text(quadrant.displayTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundColor(quadrant.tintColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected ? quadrant.backgroundColor : Color.holoCardBackground)
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.holoPrimary.opacity(0.55) : Color.holoBorder,
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(quadrant.displayTitle)，\(count)项"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(String(localized: "查看任务"))
    }
}
