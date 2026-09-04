//
//  HoloAdaptiveLayout.swift
//  Holo
//
//  iPad/大屏自适应布局工具层（iPad 适配方案 docs/ipad-adaptation/plan.md Phase 1 基建）
//  策略：限宽居中——compact 宽度（iPhone）自然撑满、行为与不包裹完全一致；
//  regular 宽度（iPad 全屏）内容列限宽居中，两侧留白透出全局背景色。
//

import SwiftUI

/// 全局自适应布局常量（集中管理，禁止在业务视图里散落魔法数字）
enum HoloAdaptiveLayout {

    /// regular 宽度下内容列的最大宽度。
    /// iPad 竖屏 768–834pt / 横屏 1024–1366pt，内容列恒定，
    /// 横竖屏切换只改变两侧留白、不触发内容重排。
    static let contentColumnMaxWidth: CGFloat = 720

    /// 判断当前水平 size class 是否为 regular（iPad 全屏恒为 regular；iPhone 恒为 compact）
    static func isRegularWidth(_ sizeClass: UserInterfaceSizeClass?) -> Bool {
        sizeClass == .regular
    }

    // MARK: - v2 宽度断点（docs/ipad-adaptation/v2-plan.md 阶段 1）

    /// expanded 档阈值：12.9 横屏（1366）/ 11 寸横屏（1160）/ 12.9 竖屏（1024）达标，
    /// 11 寸竖屏（834）与 iPhone 落在 compact/medium。
    /// 达标即启用侧边栏骨架、模块内顶部切换、通铺布局。
    static let expandedWidthThreshold: CGFloat = 1024

    /// 侧边栏宽度（v2 骨架，见设计稿 ipad-v2-0-skeleton-prototype.html）
    static let sidebarWidth: CGFloat = 232

    static func isExpandedWidth(_ width: CGFloat?) -> Bool {
        guard let width else { return false }
        return width >= expandedWidthThreshold
    }

    /// 实时窗口宽度。仅供快捷键命令、总线处理等**非视图**代码在事件瞬间读取；
    /// 视图内一律用 `holoWindowWidth` 环境（旋转时自动刷新），避免读屏幕尺寸的
    /// static 值不触发 SwiftUI 重算的问题。
    static var currentWindowWidth: CGFloat? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow.bounds.width
            }
        }
        return nil
    }
}

// MARK: - 窗口宽度环境

/// 窗口宽度环境键：由 ContentView 根部 GeometryReader 注入。
/// 旋转 / 窗口变化时所有读取环境的视图自动重算。
private struct HoloWindowWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// 当前窗口宽度（pt）。未注入（理论上不会发生）时为 nil，按最窄档处理。
    var holoWindowWidth: CGFloat? {
        get { self[HoloWindowWidthKey.self] }
        set { self[HoloWindowWidthKey.self] = newValue }
    }
}

/// 三档宽度档位：compact（手机）/ medium（iPad 窄形态与竖屏）/ expanded（宽屏通铺）
enum HoloWidthTier {
    case compact
    case medium
    case expanded

    init(width: CGFloat?, isRegular: Bool) {
        if HoloAdaptiveLayout.isExpandedWidth(width) {
            self = .expanded
        } else if isRegular {
            self = .medium
        } else {
            self = .compact
        }
    }
}

/// 限宽居中容器：iPad 上内容像「报纸栏目」居中，两侧留白显示全局背景。
struct ContentColumnContainer<Content: View>: View {

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// 内容列最大宽度，默认全局常量；个别模块需要更宽时在调用处覆盖
    private let maxWidth: CGFloat
    private let content: () -> Content

    init(
        maxWidth: CGFloat = HoloAdaptiveLayout.contentColumnMaxWidth,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.maxWidth = maxWidth
        self.content = content
    }

    var body: some View {
        if HoloAdaptiveLayout.isRegularWidth(horizontalSizeClass) {
            content()
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        } else {
            content()
        }
    }
}

// MARK: - 便捷用法

/// 限宽修饰器：regular 宽度下内容限宽居中。
/// paintsBackground=true 时自带全幅背景衬底（覆盖层/弹层没有外层背景可依赖，
/// 两侧留白须自己画，否则露出系统底色）。
/// paintsBackground=false 时只做限宽居中——模块容器已有全屏背景时用这档，
/// 避免内嵌 ignoresSafeArea 的背景层与外层 safeAreaInset（吸底 Tab 栏）互相干扰，
/// 导致 Tab 栏宽度提议也被限到列宽。
struct HoloContentColumnModifier: ViewModifier {

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let maxWidth: CGFloat
    let paintsBackground: Bool

    func body(content: Content) -> some View {
        if HoloAdaptiveLayout.isRegularWidth(horizontalSizeClass) {
            if paintsBackground {
                ZStack {
                    Color.holoBackground.ignoresSafeArea()
                    content
                        .frame(maxWidth: maxWidth)
                }
            } else {
                content
                    .frame(maxWidth: maxWidth)
                    .frame(maxWidth: .infinity)
            }
        } else {
            content
        }
    }
}

extension View {

    /// 把内容包进限宽居中容器：iPhone 无感（自然撑满），iPad 内容列居中、
    /// 两侧画全幅背景。骨架层（ContentView 三 tab）与全屏覆盖层内容统一用它。
    func holoContentColumn(maxWidth: CGFloat = HoloAdaptiveLayout.contentColumnMaxWidth,
                           paintsBackground: Bool = true) -> some View {
        modifier(HoloContentColumnModifier(maxWidth: maxWidth, paintsBackground: paintsBackground))
    }
}
