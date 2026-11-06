//
//  TaskQuadrantOverview.swift
//  Holo
//
//  紧凑 2×2 象限总览（方案 §4.1/§4.3/§10.1）：象限只放标题、数量和一行引导；
//  浅暖底色辅助区分、主文字高对比深色；数量只统计当前范围活动未完成任务。
//

import SwiftUI
#if canImport(UIKit)
#else
import AppKit
#endif

// MARK: - 象限语义色（§10.1 原型色值，Light/Dark 双值；hex 不散写进各 View）

private func quadrantDynamicColor(light: UInt32, dark: UInt32) -> Color {
    #if canImport(UIKit)
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(rgb: dark)
            : UIColor(rgb: light)
    })
    #else
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(rgb: dark)
            : NSColor(rgb: light)
    })
    #endif
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
    /// 象限主文字色（2026-11-05 原型 task-quadrant-redesign 拍板值；Dark 沿用旧浅色待适配）
    var tintColor: Color {
        switch self {
        case .doFirst: return quadrantDynamicColor(light: 0xB3402E, dark: 0xF0A48E)
        case .scheduleTime: return quadrantDynamicColor(light: 0x22764A, dark: 0xADD1B3)
        case .batchHandle: return quadrantDynamicColor(light: 0x8A5A12, dark: 0xDDC07E)
        case .reviewLater: return quadrantDynamicColor(light: 0x6757A8, dark: 0xC4C3D4)
        case .unclassified: return Color.holoTextSecondary
        }
    }

    /// 象限浅底色（格头彩底；2026-11-05 原型值）
    var backgroundColor: Color {
        switch self {
        case .doFirst: return quadrantDynamicColor(light: 0xFAE9E4, dark: 0x3C2927)
        case .scheduleTime: return quadrantDynamicColor(light: 0xE6F1EA, dark: 0x28352D)
        case .batchHandle: return quadrantDynamicColor(light: 0xFAEFD3, dark: 0x383222)
        case .reviewLater: return quadrantDynamicColor(light: 0xECEAF6, dark: 0x30303D)
        case .unclassified: return Color.holoCardBackground
        }
    }
}

// MARK: - 四象限页调色板（2026-11-05 原型 CSS 值集中定义；深色适配后续一处改）

/// 原型 task-quadrant-redesign 的页面级颜色。深色模式本次不验收，
/// 全部浅色值集中在此，后续适配只动这一个定义点。
enum TaskQuadrantPalette {
    /// 主文字 #26241F
    static let ink = Color(red: 0x26 / 255, green: 0x24 / 255, blue: 0x1F / 255)
    /// 次级文字 #8A867C
    static let inkSecondary = Color(red: 0x8A / 255, green: 0x86 / 255, blue: 0x7C / 255)
    /// 弱文字 #B8B2A5
    static let inkTertiary = Color(red: 0xB8 / 255, green: 0xB2 / 255, blue: 0xA5 / 255)
    /// 任务行 meta #7C776B
    static let meta = Color(red: 0x7C / 255, green: 0x77 / 255, blue: 0x6B / 255)
    /// 逾期红 #C03A28
    static let late = Color(red: 0xC0 / 255, green: 0x3A / 255, blue: 0x28 / 255)
    /// 勾选圈描边 #C9C5BA
    static let ringBorder = Color(red: 0xC9 / 255, green: 0xC5 / 255, blue: 0xBA / 255)
    /// 勾选圈描边取色（唯一源）：逾期 rgba(192,58,40,.45)，常态 #C9C5BA——
    /// 格内/侧栏/浮卡共用，保证三处视觉一致
    static func ringStroke(isOverdue: Bool) -> Color {
        isOverdue ? late.opacity(0.45) : ringBorder
    }
    /// 分隔线 #ECEAE3
    static let line = Color(red: 0xEC / 255, green: 0xEA / 255, blue: 0xE3 / 255)
    /// 填充底 #F1EFE9（输入框 / 分段轨道 / 徽章底）
    static let fill = Color(red: 0xF1 / 255, green: 0xEF / 255, blue: 0xE9 / 255)
    /// 品牌橙 #E85D2B（FAB / 选中 tab / 把手底）
    static let accent = Color(red: 0xE8 / 255, green: 0x5D / 255, blue: 0x2B / 255)
    /// 新建主按钮默认绿 #22764A（原型与绿格深色同值）
    static let addGreen = Color(red: 0x22 / 255, green: 0x76 / 255, blue: 0x4A / 255)
    /// 把手与徽章文字 #C24E22
    static let handleText = Color(red: 0xC2 / 255, green: 0x4E / 255, blue: 0x22 / 255)
    /// 侧栏奶油底 #FCFBF7（叠在毛玻璃上）
    static let sidebarTint = Color(red: 0xFC / 255, green: 0xFB / 255, blue: 0xF7 / 255)
    /// 拖拽落点胶囊深底 #2A2823
    static let capsule = Color(red: 0x2A / 255, green: 0x28 / 255, blue: 0x23 / 255)
    /// 占位虚线 #D6D2C6
    static let dash = Color(red: 0xD6 / 255, green: 0xD2 / 255, blue: 0xC6 / 255)
    /// 遮罩暖黑 rgba(22,20,15,x)
    static func scrim(_ opacity: Double) -> Color {
        Color(red: 22 / 255, green: 20 / 255, blue: 15 / 255).opacity(opacity)
    }
}

// MARK: - 象限胶囊总览（2026-10-11 列表减法）

/// 零值象限不出场；有值的象限瘦成一粒胶囊（无教学句、无四色大卡）。
/// 四象限全零时整行自然隐藏。选中态 = 象限底色 + 品牌描边。
struct TaskQuadrantOverview: View {
    /// 四象限数量（不含待确认）
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
