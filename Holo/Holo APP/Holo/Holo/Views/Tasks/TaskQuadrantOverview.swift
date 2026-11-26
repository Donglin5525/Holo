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

private func quadrantDynamicColor(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
    #if canImport(UIKit)
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(rgb: dark, alpha: darkAlpha)
            : UIColor(rgb: light, alpha: lightAlpha)
    })
    #else
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(rgb: dark, alpha: darkAlpha)
            : NSColor(rgb: light, alpha: lightAlpha)
    })
    #endif
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}
#else
private extension NSColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}
#endif

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

// MARK: - 四象限页调色板（明暗双模式集中定义）

/// 四象限页与新建任务弹层的页面级语义色（Light / Dark 双模式）。
enum TaskQuadrantPalette {
    /// 主文字：浅 #26241F / 深 #F3F1EC
    static let ink = quadrantDynamicColor(light: 0x26241F, dark: 0xF3F1EC)
    /// 次级文字：浅 #8A867C / 深 #A39E93
    static let inkSecondary = quadrantDynamicColor(light: 0x8A867C, dark: 0xA39E93)
    /// 弱文字：浅 #B8B2A5 / 深 #757168
    static let inkTertiary = quadrantDynamicColor(light: 0xB8B2A5, dark: 0x757168)
    /// 任务行 meta：浅 #7C776B / 深 #9E998E
    static let meta = quadrantDynamicColor(light: 0x7C776B, dark: 0x9E998E)
    /// 逾期红：浅 #C03A28 / 深 #F27B6B
    static let late = quadrantDynamicColor(light: 0xC03A28, dark: 0xF27B6B)
    /// 勾选圈常态描边：浅 #C9C5BA / 深 #63605A
    static let ringBorder = quadrantDynamicColor(light: 0xC9C5BA, dark: 0x63605A)
    /// 勾选圈逾期描边：浅 rgba(192,58,40,.45) / 深 rgba(242,123,107,.65)
    private static let ringOverdueBorder = quadrantDynamicColor(
        light: 0xC03A28, dark: 0xF27B6B, lightAlpha: 0.45, darkAlpha: 0.65
    )
    /// 勾选圈描边取色（唯一源）：格内/侧栏/浮卡共用，保证三处视觉一致
    static func ringStroke(isOverdue: Bool) -> Color {
        isOverdue ? ringOverdueBorder : ringBorder
    }
    /// 分隔线：浅 #ECEAE3 / 深 #3A3A3D
    static let line = quadrantDynamicColor(light: 0xECEAE3, dark: 0x3A3A3D)
    /// 填充底（输入框 / 分段轨道 / 关闭圆底 / 日期胶囊底）：浅 #F1EFE9 / 深 #38383B
    static let fill = quadrantDynamicColor(light: 0xF1EFE9, dark: 0x38383B)
    /// 分段控件选中滑块底：浅 #FFFFFF / 深 #4E4E52（与 fill 轨道自然分层）
    static let segmentThumb = quadrantDynamicColor(light: 0xFFFFFF, dark: 0x4E4E52)
    /// 品牌橙（FAB / 选中 tab / 把手底）：浅 #E85D2B / 深 #F27344
    static let accent = quadrantDynamicColor(light: 0xE85D2B, dark: 0xF27344)
    /// 新建主按钮默认绿：浅 #22764A / 深 #2F8F5C
    static let addGreen = quadrantDynamicColor(light: 0x22764A, dark: 0x2F8F5C)
    /// 把手与待确认徽章文字：浅 #C24E22 / 深 #F5956B
    static let handleText = quadrantDynamicColor(light: 0xC24E22, dark: 0xF5956B)
    /// 侧栏叠底（叠在毛玻璃上）：浅 #FCFBF7 / 深 #1E1E20
    static let sidebarTint = quadrantDynamicColor(light: 0xFCFBF7, dark: 0x1E1E20)
    /// 拖拽落点胶囊深底：浅 #2A2823 / 深 #3C3A36
    static let capsule = quadrantDynamicColor(light: 0x2A2823, dark: 0x3C3A36)
    /// 拖拽条与占位虚线：浅 #D6D2C6 / 深 #54524D
    static let dash = quadrantDynamicColor(light: 0xD6D2C6, dark: 0x54524D)
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
