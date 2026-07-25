//
//  DirectionalChartGestureOverlay.swift
//  Holo
//
//  图表方向手势覆盖层（财务统计分析各图表共享）
//  横向拖动由图表独占（滑动查看数值），纵向或模糊方向在识别开始前交还父级 ScrollView
//

import SwiftUI
import UIKit

// MARK: - 图表方向手势

/// UIKit 的 pan delegate 能在识别开始前拒绝纵向拖动。
/// 这与“识别后不处理纵向值”不同：拒绝后父级 ScrollView 可直接接管，不会出现首帧卡顿。
final class DirectionalChartGestureView: UIView {
    var onHierarchyReady: ((UIView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onHierarchyReady?(self)
        }
    }
}

struct DirectionalChartGestureOverlay: UIViewRepresentable {
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onCancelled: () -> Void
    /// 点按回调。为 nil 时点按回退到 onEnded（与拖动结束同一出口）
    var onTap: ((CGPoint) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled,
            onTap: onTap
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = DirectionalChartGestureView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = true
        context.coordinator.chartPanGesture = pan

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        tap.require(toFail: pan)

        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        view.onHierarchyReady = { [weak coordinator = context.coordinator] view in
            coordinator?.prioritizeChartPan(overParentScrollViewFrom: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
        context.coordinator.onTap = onTap
        DispatchQueue.main.async {
            context.coordinator.prioritizeChartPan(overParentScrollViewFrom: uiView)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGPoint) -> Void
        var onEnded: (CGPoint) -> Void
        var onCancelled: () -> Void
        var onTap: ((CGPoint) -> Void)?
        weak var chartPanGesture: UIPanGestureRecognizer?
        weak var prioritizedParentScrollView: UIScrollView?

        init(
            onChanged: @escaping (CGPoint) -> Void,
            onEnded: @escaping (CGPoint) -> Void,
            onCancelled: @escaping () -> Void,
            onTap: ((CGPoint) -> Void)?
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
            self.onTap = onTap
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)

            switch recognizer.state {
            case .began, .changed:
                onChanged(location)
            case .ended:
                onEnded(location)
            case .cancelled, .failed:
                onCancelled()
            default:
                break
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            if let onTap {
                onTap(location)
            } else {
                onEnded(location)
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else {
                return true
            }

            return ChartGestureArbitration.shouldBeginHorizontalPan(
                velocity: pan.velocity(in: view)
            )
        }

        /// 父级滚动必须先等待图表判定方向：
        /// 横向时图表独占，纵向或模糊方向时图表失败并立即交还页面滚动。
        func prioritizeChartPan(overParentScrollViewFrom view: UIView) {
            guard let chartPanGesture else { return }

            var ancestor = view.superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    guard prioritizedParentScrollView !== scrollView else { return }
                    scrollView.panGestureRecognizer.require(toFail: chartPanGesture)
                    prioritizedParentScrollView = scrollView
                    return
                }
                ancestor = current.superview
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            ChartGestureArbitration.allowsSimultaneousRecognition
        }
    }
}
