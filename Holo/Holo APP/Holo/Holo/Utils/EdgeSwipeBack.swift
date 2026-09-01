//
//  EdgeSwipeBack.swift
//  Holo
//
//  全屏页（fullScreenCover）边缘右滑返回：从屏幕左缘向右滑即返回。
//
//  为什么存在：系统右滑返回只属于 NavigationStack push，fullScreenCover 没有——
//  这是全局交互规则（开发守则「全屏页必须提供边缘右滑返回」）：
//  任何全屏推入的阅读页/详情页都必须挂 .holoEdgeSwipeBack，不能只留左上角按钮。
//
//  实现用 UIScreenEdgePanGestureRecognizer（UIKit 桥）而非 SwiftUI DragGesture：
//  只识别屏幕左缘，天然不与页面内的 List/ScrollView 横向滑动、
//  swipeActions 抢手势（SwiftUI 手势挂全页会挡子级滚动的坑已有前科）。
//

import SwiftUI
import UIKit

struct EdgeSwipeBackRepresentable: UIViewControllerRepresentable {
    var onBack: () -> Void
    /// false 时不识别手势：用于「同一视图多形态」的页面（如全屏详情/导航栈 push 共用），
    /// push 形态保留系统返回，两种边缘手势并存会双重 pop
    var isEnabled: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(onBack: onBack)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = true

        let pan = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.edges = .left
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        controller.view.addGestureRecognizer(pan)
        context.coordinator.gesture = pan
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.onBack = onBack
        context.coordinator.gesture?.isEnabled = isEnabled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBack: () -> Void
        weak var gesture: UIScreenEdgePanGestureRecognizer?

        init(onBack: @escaping () -> Void) {
            self.onBack = onBack
        }

        @objc func handlePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            onBack()
        }

        /// 与页面内其它手势（List 滚动/swipeActions）共存，互不独占
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

extension View {
    /// 全屏页边缘右滑返回。挂在使用 fullScreenCover 呈现的页面根部。
    /// isEnabled=false 时不识别（多形态页面 push 形态让位给系统返回）。
    func holoEdgeSwipeBack(isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        background(EdgeSwipeBackRepresentable(onBack: action, isEnabled: isEnabled))
    }
}
