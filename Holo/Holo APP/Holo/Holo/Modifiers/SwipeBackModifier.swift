//
//  SwipeBackModifier.swift
//  Holo
//
//  可复用的右滑返回手势修饰器
//  使用 UIScreenEdgePanGestureRecognizer，不会与 ScrollView 冲突
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SwipeBackModifier

/// 右滑返回手势修饰器
/// 基于 UIScreenEdgePanGestureRecognizer，从屏幕左侧边缘右滑触发页面关闭
/// 不会与内部 ScrollView 的滚动手势冲突
struct SwipeBackModifier: ViewModifier {

    // MARK: - Properties

    /// 是否启用手势
    let isEnabled: Bool

    /// 关闭回调
    let onDismiss: () -> Void

    /// 当前偏移量
    @State private var offset: CGFloat = 0

    // MARK: - Init

    init(
        isEnabled: Bool = true,
        onDismiss: @escaping () -> Void
    ) {
        self.isEnabled = isEnabled
        self.onDismiss = onDismiss
    }

    // MARK: - Body

    func body(content: Content) -> some View {
        content
            .offset(x: isEnabled ? offset : 0)
            // 滑动时右边缘产生阴影，增加层次感
            .shadow(
                color: isEnabled && offset > 0
                    ? .black.opacity(min(0.2, Double(offset / screenWidth) * 0.4))
                    : .clear,
                radius: 10,
                x: offset > 0 ? -3 : 0
            )
            .overlay(
                EdgeGestureOverlay(
                    isEnabled: isEnabled,
                    onTranslate: { rawTranslation in
                        // 阻尼效果：超过 40% 屏宽后逐渐减速，模拟物理手感
                        let threshold = screenWidth * 0.4
                        if rawTranslation <= threshold {
                            offset = rawTranslation
                        } else {
                            let excess = rawTranslation - threshold
                            offset = threshold + excess * 0.3
                        }
                    },
                    onEnd: { velocity in
                        // 阈值：滑动超过 35% 屏宽 或 速度足够快
                        let shouldDismiss = offset > screenWidth * 0.35 || velocity > 500

                        if shouldDismiss {
                            dismissWithVelocity(velocity)
                        } else {
                            snapBack()
                        }
                    }
                )
            )
    }

    // MARK: - 屏幕宽度

    private var screenWidth: CGFloat {
        UIScreen.main.bounds.width
    }

    // MARK: - 关闭动画（速度自适应）

    private func dismissWithVelocity(_ velocity: CGFloat) {
        let remaining = screenWidth - offset
        let safeVelocity = max(velocity, 300)
        let duration = min(0.3, Double(remaining / safeVelocity))

        withAnimation(.easeOut(duration: max(0.15, duration))) {
            offset = screenWidth
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.15, duration) + 0.02) {
            onDismiss()
        }
    }

    // MARK: - 回弹动画（柔和弹簧）

    private func snapBack() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            offset = 0
        }
    }
}

// MARK: - Edge Gesture Overlay

/// 基于 UIScreenEdgePanGestureRecognizer 的手势覆盖层
/// 仅拦截左侧边缘手势，其余触摸穿透到下层视图
private struct EdgeGestureOverlay: UIViewRepresentable {

    let isEnabled: Bool
    let onTranslate: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> EdgeGestureHostView {
        let view = EdgeGestureHostView()

        let recognizer = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGesture(_:))
        )
        recognizer.edges = .left
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        context.coordinator.recognizer = recognizer

        return view
    }

    func updateUIView(_ uiView: EdgeGestureHostView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
    }

    // MARK: - Coordinator

    class Coordinator {
        var parent: EdgeGestureOverlay
        weak var recognizer: UIScreenEdgePanGestureRecognizer?

        init(_ parent: EdgeGestureOverlay) {
            self.parent = parent
        }

        @objc func handleGesture(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard let view = recognizer.view?.superview else { return }
            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)

            switch recognizer.state {
            case .changed:
                parent.onTranslate(max(0, translation.x))
            case .ended:
                parent.onEnd(velocity.x)
            case .cancelled:
                parent.onEnd(0)
            default:
                break
            }
        }
    }
}

// MARK: - Edge Gesture Host View

/// 仅响应左侧边缘区域触摸的 UIView
/// 非边缘触摸返回 nil，穿透到下层视图（ScrollView 等）
private class EdgeGestureHostView: UIView {
    private let edgeWidth: CGFloat = 20

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard point.x < edgeWidth,
              isUserInteractionEnabled,
              !isHidden,
              alpha > 0.01
        else { return nil }
        return super.hitTest(point, with: event)
    }
}

// MARK: - View Extension

extension View {
    /// 添加右滑返回手势
    /// - Parameters:
    ///   - isEnabled: 是否启用手势（默认 true）
    ///   - onDismiss: 关闭回调
    /// - Returns: 应用了手势的视图
    func swipeBackToDismiss(
        isEnabled: Bool = true,
        onDismiss: @escaping () -> Void
    ) -> some View {
        self.modifier(SwipeBackModifier(
            isEnabled: isEnabled,
            onDismiss: onDismiss
        ))
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Text("从左边缘右滑返回")
            .font(.holoHeading)
            .foregroundColor(.holoTextPrimary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.holoBackground)
    .swipeBackToDismiss {
        // Preview 中无法实际 dismiss
    }
}
