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

// MARK: - 象限格

struct TaskQuadrantCell: View {
    let quadrant: TaskQuadrant
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(quadrant.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(quadrant.tintColor)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(count)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(quadrant.tintColor)
                }
                Text(quadrant.guidance)
                    .font(.holoTinyLabel)
                    .foregroundColor(quadrant.tintColor.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(quadrant.backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.holoPrimary.opacity(0.6) : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(quadrant.displayTitle)，\(quadrant.axisDescription)，\(count)项"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(String(localized: "查看任务"))
    }
}

// MARK: - 2×2 总览

struct TaskQuadrantOverview: View {
    /// 四象限数量（不含待整理）
    let countsByQuadrant: [TaskQuadrant: Int]
    /// 当前选中的象限（nil = 全部）
    let selectedQuadrant: TaskQuadrant?
    let onQuadrantTap: (TaskQuadrant) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
            ForEach(TaskQuadrant.overviewOrder, id: \.self) { quadrant in
                TaskQuadrantCell(
                    quadrant: quadrant,
                    count: countsByQuadrant[quadrant] ?? 0,
                    isSelected: selectedQuadrant == quadrant
                ) {
                    onQuadrantTap(quadrant)
                }
            }
        }
    }
}
