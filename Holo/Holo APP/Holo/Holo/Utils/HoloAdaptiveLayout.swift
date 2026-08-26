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

/// 限宽修饰器：regular 宽度下内容限宽居中，并自带全幅背景衬底
/// （覆盖层/弹层没有外层背景可依赖，两侧留白须自己画，否则露出系统底色）。
struct HoloContentColumnModifier: ViewModifier {

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        if HoloAdaptiveLayout.isRegularWidth(horizontalSizeClass) {
            ZStack {
                Color.holoBackground.ignoresSafeArea()
                content
                    .frame(maxWidth: maxWidth)
            }
        } else {
            content
        }
    }
}

extension View {

    /// 把内容包进限宽居中容器：iPhone 无感（自然撑满），iPad 内容列居中、
    /// 两侧画全幅背景。骨架层（ContentView 三 tab）与全屏覆盖层内容统一用它。
    func holoContentColumn(maxWidth: CGFloat = HoloAdaptiveLayout.contentColumnMaxWidth) -> some View {
        modifier(HoloContentColumnModifier(maxWidth: maxWidth))
    }
}
