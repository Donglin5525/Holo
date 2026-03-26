//
//  SwipeBackModifier.swift
//  Holo
//
//  可复用的右滑返回手势修饰器
//  从屏幕左侧边缘右滑触发页面关闭
//

import SwiftUI

// MARK: - SwipeBackModifier

/// 右滑返回手势修饰器
/// 从屏幕左侧 40pt 区域内右滑超过 120pt 即可关闭页面
struct SwipeBackModifier: ViewModifier {

    // MARK: - Properties

    /// 是否启用手势
    let isEnabled: Bool

    /// 触发区域宽度（从左边缘起）
    let edgeWidth: CGFloat

    /// 触发所需滑动距离
    let triggerDistance: CGFloat

    /// 关闭回调
    let onDismiss: () -> Void

    /// 当前偏移量
    @State private var offset: CGFloat = 0

    /// 视图宽度（通过背景 GeometryReader 获取）
    @State private var viewWidth: CGFloat = 0

    // MARK: - Defaults

    /// 默认触发区域宽度
    static let defaultEdgeWidth: CGFloat = 40

    /// 默认触发距离
    static let defaultTriggerDistance: CGFloat = 120

    // MARK: - Init

    init(
        isEnabled: Bool = true,
        edgeWidth: CGFloat = defaultEdgeWidth,
        triggerDistance: CGFloat = defaultTriggerDistance,
        onDismiss: @escaping () -> Void
    ) {
        self.isEnabled = isEnabled
        self.edgeWidth = edgeWidth
        self.triggerDistance = triggerDistance
        self.onDismiss = onDismiss
    }

    // MARK: - Body

    func body(content: Content) -> some View {
        content
            .offset(x: isEnabled ? offset : 0)
            .gesture(
                isEnabled ?
                DragGesture(minimumDistance: 10)
                    .onChanged { v in
                        // 仅在从左侧边缘区域内起始的右滑手势生效
                        if v.startLocation.x < edgeWidth && v.translation.width > 0 {
                            offset = v.translation.width
                        }
                    }
                    .onEnded { v in
                        // 判断是否触发关闭
                        if v.startLocation.x < edgeWidth && v.translation.width > triggerDistance {
                            // 滑动足够距离，执行关闭动画
                            // 使用已获取的宽度或一个足够大的值
                            let targetOffset = viewWidth > 0 ? viewWidth : 500
                            withAnimation(.easeOut(duration: 0.25)) {
                                offset = targetOffset
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                onDismiss()
                            }
                        } else {
                            // 回弹动画
                            withAnimation(.spring(response: 0.3)) {
                                offset = 0
                            }
                        }
                    }
                : nil
            )
            // 使用 background GeometryReader 获取宽度，不影响布局
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { viewWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, newWidth in
                            viewWidth = newWidth
                        }
                }
            )
    }
}

// MARK: - View Extension

extension View {
    /// 添加右滑返回手势
    /// - Parameters:
    ///   - isEnabled: 是否启用手势（默认 true）
    ///   - edgeWidth: 触发区域宽度（默认 40pt）
    ///   - triggerDistance: 触发所需滑动距离（默认 120pt）
    ///   - onDismiss: 关闭回调
    /// - Returns: 应用了手势的视图
    func swipeBackToDismiss(
        isEnabled: Bool = true,
        edgeWidth: CGFloat = SwipeBackModifier.defaultEdgeWidth,
        triggerDistance: CGFloat = SwipeBackModifier.defaultTriggerDistance,
        onDismiss: @escaping () -> Void
    ) -> some View {
        self.modifier(SwipeBackModifier(
            isEnabled: isEnabled,
            edgeWidth: edgeWidth,
            triggerDistance: triggerDistance,
            onDismiss: onDismiss
        ))
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        VStack {
            Text("从左边缘右滑返回")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.holoBackground)
        .swipeBackToDismiss {
            print("Dismiss triggered")
        }
    }
}
