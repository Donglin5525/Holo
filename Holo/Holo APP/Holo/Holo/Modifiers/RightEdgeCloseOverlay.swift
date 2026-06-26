//
//  RightEdgeCloseOverlay.swift
//  Holo
//
//  右边缘左滑关闭手势覆盖层（P1.5.5）
//  知识树抽屉打开时挂载，从屏幕右边缘左滑关闭抽屉
//  UIScreenEdgePanGestureRecognizer(.right) + HorizontalGestureLock 方向判定
//  不复用 SwipeBackModifier（后者是整页 offset 跟手；抽屉用 .transition 动画，只需触发关闭）
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 右边缘左滑关闭手势覆盖层
struct RightEdgeCloseOverlay: UIViewRepresentable {

    let isEnabled: Bool
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> RightEdgeHostView {
        let view = RightEdgeHostView()
        let recognizer = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGesture(_:))
        )
        recognizer.edges = .right
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        context.coordinator.recognizer = recognizer
        return view
    }

    func updateUIView(_ uiView: RightEdgeHostView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
    }

    // MARK: - Coordinator

    class Coordinator {
        var parent: RightEdgeCloseOverlay
        weak var recognizer: UIScreenEdgePanGestureRecognizer?
        private var gestureLock = HorizontalGestureLock()

        init(_ parent: RightEdgeCloseOverlay) { self.parent = parent }

        @objc func handleGesture(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)

            switch recognizer.state {
            case .began:
                gestureLock.reset()
            case .changed:
                _ = gestureLock.update(translation: translation)
            case .ended:
                // 右边缘左滑：水平锁定 + translation.x < 0（向左）
                if gestureLock.axis == .horizontal && translation.x < 0 {
                    parent.onClose()
                }
                gestureLock.reset()
            case .cancelled:
                gestureLock.reset()
            default:
                break
            }
        }
    }
}

// MARK: - 右边缘 Host View

/// 仅响应右侧边缘触摸的 UIView（point.x > width - edgeWidth），其余穿透
class RightEdgeHostView: UIView {
    private let edgeWidth: CGFloat = 20

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard point.x > bounds.width - edgeWidth,
              isUserInteractionEnabled,
              !isHidden,
              alpha > 0.01
        else { return nil }
        return super.hitTest(point, with: event)
    }
}
