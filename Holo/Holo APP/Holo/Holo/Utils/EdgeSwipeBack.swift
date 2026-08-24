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
        controller.view.addGestureRecognizer(pan)
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.onBack = onBack
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBack: () -> Void

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
    func holoEdgeSwipeBack(action: @escaping () -> Void) -> some View {
        background(EdgeSwipeBackRepresentable(onBack: action))
    }
}
