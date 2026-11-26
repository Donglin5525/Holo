//
//  HoloEditorialPrimitives.swift
//  Holo
//
//  公共组件底座（2026-11-24 反 AI 味审美升维）：
//  把「默认无卡、一页一橙、图标克制、双轨排印、去圆体、去 sparkles」
//  沉淀为开箱即用的基础组件，替代各页面手搓圆角白卡、阴影与橙色按钮。
//
//  对应规范：docs/standards/设计规范.md（2026-11-24 反 AI 味减法红线 & §13）
//  机器守门：BuildScripts/aesthetic_guard.py
//

import SwiftUI

// MARK: - 1. 图标尺寸收敛档位（§13 待统一项 → 已封装）

/// 全 App 图标尺寸收敛到 5 档，禁止继续散落 18 种魔法字号。
enum HoloIconSize: CGFloat, CaseIterable {
    /// 角标 / 微型辅助（12pt）
    case xs = 12
    /// 行内次级图标 / 芯片（15pt）
    case sm = 15
    /// 导航 / 操作按钮（18pt）
    case md = 18
    /// 功能入口 / 重点图标（22pt）
    case lg = 22
    /// 大号实体图标（28pt）
    case xl = 28
}

extension View {
    /// 统一图标尺寸与字重（仅用于图标，正文/标题请用 `.holoText(...)`）。
    func holoIconSize(_ size: HoloIconSize, weight: Font.Weight = .medium) -> some View {
        font(.system(size: size.rawValue, weight: weight))
    }
}

// MARK: - 2. 语义按钮样式（一页一橙，§13 待统一项 → 已封装）

/// 主行动按钮样式：全屏仅用于 1–2 处核心主操作（一页一橙）。
/// 44pt 最小热区，走 `holoToolAction` / `holoToolOnAction` 与 `HoloAnimation.pressScale`。
struct HoloPrimaryButtonStyle: ButtonStyle {
    var isCapsule: Bool = true
    var fillsWidth: Bool = false

    @AppStorage(HoloMotionRollout.interactionKey) private var motionEnabled = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let cornerRadius: CGFloat = isCapsule ? 999 : HoloRadius.md
        configuration.label
            .holoText(.supporting)
            .fontWeight(.semibold)
            .padding(.horizontal, HoloSpacing.md)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
            .foregroundStyle(isEnabled ? Color.holoToolOnAction : Color.holoToolTextSecondary)
            .background(isEnabled ? Color.holoToolAction : Color.holoToolInset)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(isEnabled && configuration.isPressed ? 0.84 : 1)
            .scaleEffect(configuration.isPressed && motionEnabled && !reduceMotion ? HoloAnimation.pressScale : 1)
            .animation(reduceMotion || !motionEnabled ? nil : HoloAnimation.quick, value: configuration.isPressed)
    }
}

/// 次要按钮样式：暖墨描边 + 纸底，不抢朱砂主焦点（替代页面内滥用多个橙色按钮）。
struct HoloSecondaryButtonStyle: ButtonStyle {
    var isCapsule: Bool = true
    var fillsWidth: Bool = false

    @AppStorage(HoloMotionRollout.interactionKey) private var motionEnabled = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let cornerRadius: CGFloat = isCapsule ? 999 : HoloRadius.md
        configuration.label
            .holoText(.supporting)
            .fontWeight(.medium)
            .padding(.horizontal, HoloSpacing.md)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
            .foregroundStyle(isEnabled ? Color.holoToolText : Color.holoToolTextSecondary)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.holoToolBorder, lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(isEnabled && configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed && motionEnabled && !reduceMotion ? HoloAnimation.pressScale : 1)
            .animation(reduceMotion || !motionEnabled ? nil : HoloAnimation.quick, value: configuration.isPressed)
    }
}

/// 轻量文字链接按钮：用于次级跳转、AI 行式入口与空态动作，保证 44pt 垂直热区。
struct HoloGhostLinkButtonStyle: ButtonStyle {
    enum Emphasis {
        /// 暖墨主文字色（默认）
        case ink
        /// 朱砂点睛色（仅当页面无其他橙色主行动时使用）
        case accent
        /// 靛灰 AI 语义色
        case ai
    }

    var emphasis: Emphasis = .ink
    @AppStorage(HoloMotionRollout.interactionKey) private var motionEnabled = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .holoText(.supporting)
            .fontWeight(.medium)
            .foregroundStyle(foreground)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled && configuration.isPressed ? 0.55 : 1)
            .animation(reduceMotion || !motionEnabled ? nil : HoloAnimation.quick, value: configuration.isPressed)
    }

    private var foreground: Color {
        if !isEnabled { return .holoToolTextSecondary }
        switch emphasis {
        case .ink: return .holoToolText
        case .accent: return .holoToolAction
        case .ai: return .holoAI
        }
    }
}

extension ButtonStyle where Self == HoloPrimaryButtonStyle {
    static var holoPrimary: HoloPrimaryButtonStyle { HoloPrimaryButtonStyle() }
    static var holoPrimaryFullWidth: HoloPrimaryButtonStyle { HoloPrimaryButtonStyle(fillsWidth: true) }
}

extension ButtonStyle where Self == HoloSecondaryButtonStyle {
    static var holoSecondary: HoloSecondaryButtonStyle { HoloSecondaryButtonStyle() }
    static var holoSecondaryFullWidth: HoloSecondaryButtonStyle { HoloSecondaryButtonStyle(fillsWidth: true) }
}

extension ButtonStyle where Self == HoloGhostLinkButtonStyle {
    static var holoGhostInk: HoloGhostLinkButtonStyle { HoloGhostLinkButtonStyle(emphasis: .ink) }
    static var holoGhostAccent: HoloGhostLinkButtonStyle { HoloGhostLinkButtonStyle(emphasis: .accent) }
    static var holoGhostAI: HoloGhostLinkButtonStyle { HoloGhostLinkButtonStyle(emphasis: .ai) }
}

// MARK: - 3. 纸本无卡骨架线与发丝进度轨

/// 0.5pt 暖灰细线：默认无卡排版的标准分层手段，替代套白卡片。
struct HoloHairlineDivider: View {
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.holoToolBorder)
            .frame(height: 0.5)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .accessibilityHidden(true)
    }
}

/// 2pt 发丝进度轨：替代旧版 8pt 粗彩色圆角进度条。
struct HoloHairlineProgressTrack: View {
    let progress: Double
    var tint: Color = .holoAlmanacInk
    var height: CGFloat = 2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.holoToolBorder)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, proxy.size.width * clamped))
                    .animation(HoloAnimation.resolved(HoloAnimation.smooth, reduceMotion: reduceMotion), value: clamped)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int((clamped * 100).rounded()))%")
    }
}

// MARK: - 4. 纯排印区块头（从 API 上杜绝 SF Symbol Soup）

/// 纯排印区块头：刻意不提供前置装饰图标参数，用字距 + 留白 + 可选细线建立层级。
struct HoloSectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var showTopDivider: Bool = false
    @ViewBuilder let trailing: () -> Trailing

    init(
        _ title: LocalizedStringKey,
        showTopDivider: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.showTopDivider = showTopDivider
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            if showTopDivider {
                HoloHairlineDivider()
                    .padding(.bottom, HoloSpacing.xs)
            }
            HStack(alignment: .firstTextBaseline, spacing: HoloSpacing.sm) {
                Text(title)
                    .holoText(.metadata)
                    .fontWeight(.semibold)
                    .tracking(1.1)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: HoloSpacing.sm)
                trailing()
            }
        }
    }
}

extension HoloSectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, showTopDivider: Bool = false) {
        self.title = title
        self.showTopDivider = showTopDivider
        self.trailing = { EmptyView() }
    }
}

/// 区块头右侧标准次要文案视图（等宽数字、单行不折行）。
struct HoloSectionDetailLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .holoText(.metadata)
            .foregroundStyle(Color.holoToolTextSecondary)
            .monospacedDigit()
            .lineLimit(1)
    }
}

extension HoloSectionHeader where Trailing == HoloSectionDetailLabel {
    init(_ title: LocalizedStringKey, detail: String, showTopDivider: Bool = false) {
        self.title = title
        self.showTopDivider = showTopDivider
        self.trailing = { HoloSectionDetailLabel(text: detail) }
    }
}

// MARK: - 5. 默认无卡列表行（直落纸底 + 整行命中 + 0.5pt 底线）

/// 默认无卡列表行：直接落在 `holoToolBackground` 纸底上，不套白卡、不加阴影。
struct HoloCardlessRow<Content: View>: View {
    var showsDivider: Bool = true
    var verticalPadding: CGFloat = HoloSpacing.sm + 4
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            if showsDivider {
                HoloHairlineDivider()
            }
        }
    }
}

// MARK: - 6. 克制 AI 语义标识（靛灰 + 小圆点，禁用 sparkles 与紫光）

/// Holo AI 统一克制标识：靛灰 `holoAI` + `smallcircle.filled.circle`。
/// 全 App AI 来源提示与入口优先复用此组件，禁止使用 `sparkles` 或紫色渐变。
struct HoloAIBadge: View {
    var title: LocalizedStringKey = "Holo 理解"

    var body: some View {
        HStack(spacing: HoloSpacing.xs) {
            Image(systemName: "smallcircle.filled.circle")
                .holoIconSize(.xs, weight: .medium)
            Text(title)
                .holoText(.metadata)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .foregroundStyle(Color.holoAI)
        .accessibilityElement(children: .combine)
    }
}
