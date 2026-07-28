//
//  HoloScreenDismiss.swift
//  Holo
//
//  自定义 dismiss 环境，供从"全屏模块视图"返回首页使用。
//
//  背景：HomeView 历史上用 .fullScreenCover 承载各模块（财务/任务/AI…），
//  模块内部通过 @Environment(\.dismiss) 关闭自己。
//  改造为 ZStack 平级常驻后，模块不再是模态 cover，dismiss() 失效——
//  这里提供一个平替：HomeView 在 ZStack 层注入 holoDismiss = { activeScreen = nil }，
//  模块读取它来"返回首页"。
//
//  兼容性：默认值 fallback 到 @Environment(\.dismiss)，
//  这样同一个模块在 sheet/cover 场景（如 PersonalView 仍以 .sheet 呈现）
//  或 ZStack 常驻场景都能正确关闭。
//

import SwiftUI

private struct HoloScreenDismissKey: EnvironmentKey {
    /// 默认 nil：未注入时由调用方 fallback 到 @Environment(\.dismiss)
    static let defaultValue: (() -> Void)? = nil
}

private struct HoloSwipeCloseMarkerKey: EnvironmentKey {
    /// 默认 nil：未注入时右滑关闭不携带任何标记
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// 自定义全屏模块关闭动作。
    /// - 由 HomeView 在 ZStack 层注入：`{ activeScreen = nil }`
    /// - 模块内用法：`holoDismiss?() ?? dismiss()`，兼顾常驻层与 sheet 场景
    var holoDismiss: (() -> Void)? {
        get { self[HoloScreenDismissKey.self] }
        set { self[HoloScreenDismissKey.self] = newValue }
    }

    /// 右滑关闭常驻模块的标记动作。
    /// - 由 HomeView 在 ZStack 层注入：仅记录"本次关闭来自右滑手势"
    /// - SwipeBackModifier 在触发 onDismiss 前调用它，HomeView 据此把
    ///   退出转场从"下滑+淡出"换成纯淡出 —— 手势已把页面推出右边缘，
    ///   再播一次下滑转场会出现"先右后下"的重复动画
    var holoSwipeCloseMarker: (() -> Void)? {
        get { self[HoloSwipeCloseMarkerKey.self] }
        set { self[HoloSwipeCloseMarkerKey.self] = newValue }
    }
}

// MARK: - 全屏模块转场动画

/// 全屏模块在 ZStack 平级常驻时的转场动画 + 过渡样式。
///
/// 用法：切换 `activeScreen` 时用 `withAnimation(.holoScreenTransition) { activeScreen = .xxx }`，
/// 模块视图本身挂 `.transition(.holoScreenTransition)`。
///
/// 设计：模拟系统模态 cover 的"从下往上滑入 + 淡入"手感，
/// 让从系统模态迁移到 ZStack 常驻后的视觉差异尽可能小。
extension Animation {
    static var holoScreenTransition: Animation {
        .easeInOut(duration: 0.28)
    }
}

/// 全屏模块过渡样式：从下往上滑入 + 淡入；退出反向。
/// 用 `.combined(with:)` 让两个效果同时生效。
extension AnyTransition {
    static var holoScreenTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity)
        )
    }
}

