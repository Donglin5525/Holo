//
//  HoloQuietEmptyState.swift
//  Holo
//
//  文字空状态（2026-11-23 审美七项 P5）：不放图标、不放胶囊按钮，
//  只用一句衬线短句 + 一行灰色小字 + 文字链接。留白本身就是设计。
//
//  一页一橙：页面里已经有橙色主行动（比如右下角悬浮的「＋」）时，actionStyle 用 .ink。
//  文案原则：不说「暂无」「还没有数据」；不用感叹号；不卖萌、不用 emoji；主句不超过 12 个字。
//

import SwiftUI

/// 空态组件的局部排版尺寸；不改变全 App 的字号与间距 token。
enum HoloQuietEmptyStateMetrics {
    /// 滚动内容里主句上方的留白
    static let topInset: CGFloat = 92
    /// 全屏空态时上方留白占可用高度的比例
    static let flexibleTopFraction: CGFloat = 0.35
    /// 主句字号
    static let lineSize: CGFloat = 22
    /// 主句行距
    static let lineSpacing: CGFloat = 8
    /// 主句与副句的字距
    static let tracking: CGFloat = 1
    /// 主句与副句间距
    static let bylineGap: CGFloat = 14
    /// 副句与动作间距
    static let actionGap: CGFloat = 34
    /// 动作最小热区高度
    static let actionMinHeight: CGFloat = 44
    /// 动作字号
    static let actionSize: CGFloat = 15
    /// 动作下划线与文字的距离、线宽
    static let underlineGap: CGFloat = 2
    static let underlineHeight: CGFloat = 1
}

struct HoloQuietEmptyState: View {
    enum ActionStyle {
        /// holoToolAction（长廊：galleryAccent）
        case accent
        /// holoToolText（长廊：galleryInk）
        case ink
    }

    enum Palette {
        case tool, gallery
    }

    /// 主句上方的留白方式
    enum TopSpacing {
        /// 滚动内容里：固定留白
        case inset
        /// 全屏空态：按可用高度的比例留白（需要父视图给出确定高度）
        case flexible
    }

    let line: LocalizedStringKey
    var byline: LocalizedStringKey? = nil
    var actionTitle: LocalizedStringKey? = nil
    var actionStyle: ActionStyle = .accent
    var action: (() -> Void)? = nil
    var actionIdentifier: String? = nil
    var palette: Palette = .tool
    var topSpacing: TopSpacing = .inset

    private var lineColor: Color {
        palette == .gallery ? .galleryInk : .holoToolText
    }

    private var bylineColor: Color {
        palette == .gallery ? .galleryQuiet : .holoToolTextSecondary
    }

    private var actionColor: Color {
        switch (palette, actionStyle) {
        case (.gallery, .accent): .galleryAccent
        case (.gallery, .ink): .galleryInk
        case (.tool, .accent): .holoToolAction
        case (.tool, .ink): .holoToolText
        }
    }

    var body: some View {
        Group {
            switch topSpacing {
            case .inset:
                content
                    .padding(.top, HoloQuietEmptyStateMetrics.topInset)
            case .flexible:
                GeometryReader { proxy in
                    content
                        .padding(.top, proxy.size.height * HoloQuietEmptyStateMetrics.flexibleTopFraction)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var content: some View {
        VStack(spacing: 0) {
            Text(line)
                .font(.holoEditorialSerif(size: HoloQuietEmptyStateMetrics.lineSize))
                .tracking(HoloQuietEmptyStateMetrics.tracking)
                .lineSpacing(HoloQuietEmptyStateMetrics.lineSpacing)
                .foregroundStyle(lineColor)
                .multilineTextAlignment(.center)
            if let byline {
                Text(byline)
                    .holoText(.metadata)
                    .tracking(HoloQuietEmptyStateMetrics.tracking)
                    .foregroundStyle(bylineColor)
                    .multilineTextAlignment(.center)
                    .padding(.top, HoloQuietEmptyStateMetrics.bylineGap)
            }
            if let actionTitle, let action {
                actionLink(actionTitle, action: action)
                    .padding(.top, HoloQuietEmptyStateMetrics.actionGap)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 文字链接：右侧跟「→」，下方 1pt 细下划线，最小 44pt 热区。
    private func actionLink(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.xs) {
                Text(title)
                Text(verbatim: "→")
            }
            .modifier(HoloQuietEmptyStateActionFont())
            .foregroundStyle(actionColor)
            .padding(.bottom, HoloQuietEmptyStateMetrics.underlineGap + HoloQuietEmptyStateMetrics.underlineHeight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(actionColor.opacity(0.35))
                    .frame(height: HoloQuietEmptyStateMetrics.underlineHeight)
            }
            .frame(minHeight: HoloQuietEmptyStateMetrics.actionMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .holoOptionalAccessibilityIdentifier(actionIdentifier)
    }
}

/// 动作文字：15pt medium，跟随系统动态字体缩放。
private struct HoloQuietEmptyStateActionFont: ViewModifier {
    @ScaledMetric(relativeTo: .subheadline) private var size = HoloQuietEmptyStateMetrics.actionSize

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: .medium))
    }
}

private extension View {
    /// 标识为 nil 时不挂修饰，避免给没有标识的空态写入空字符串。
    @ViewBuilder
    func holoOptionalAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
