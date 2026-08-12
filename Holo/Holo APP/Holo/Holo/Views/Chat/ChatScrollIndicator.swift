//
//  ChatScrollIndicator.swift
//  Holo
//
//  聊天滚动进度条：滑动时出现，停手后淡出。
//
//  设计要点（与 ChatScrollController 完全解耦）：
//  - 组件放在 ScrollView 内部（LazyVStack.background），沿 superview 链找到祖先 UIScrollView。
//  - thumb 直接 addSubview 到 scrollView 上；通过补偿 contentOffset 让它视觉固定、不随内容滚动。
//  - 全程 KVO 驱动 UIKit，不发布任何 SwiftUI 状态，因此绝不触发 ChatView 重绘。
//

import SwiftUI
import UIKit

struct ChatScrollIndicator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: .zero)
        host.isUserInteractionEnabled = false
        host.backgroundColor = .clear
        DispatchQueue.main.async { [weak host] in
            guard let host else { return }
            context.coordinator.install(from: host)
        }
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // scrollView 可能在首帧尚未挂载，每次 SwiftUI 重绘都尝试补绑。
        context.coordinator.install(from: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var scrollView: UIScrollView?
        private var thumb: ChatScrollThumbView?
        private var offsetObservation: NSKeyValueObservation?
        private var sizeObservation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?

        func install(from host: UIView) {
            guard scrollView == nil else { return }
            if let scrollView = Self.findScrollView(from: host) {
                attach(scrollView)
            } else {
                // 视图层级可能尚未完成挂载，下一帧重试；host 被回收后自然停止。
                DispatchQueue.main.async { [weak self, weak host] in
                    guard let self, let host else { return }
                    self.install(from: host)
                }
            }
        }

        private static func findScrollView(from view: UIView) -> UIScrollView? {
            var ancestor = view.superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    return scrollView
                }
                ancestor = current.superview
            }
            return nil
        }

        private func attach(_ scrollView: UIScrollView) {
            self.scrollView = scrollView
            let thumb = ChatScrollThumbView()
            scrollView.addSubview(thumb)
            self.thumb = thumb

            offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                self?.handleScroll(sv)
            }
            sizeObservation = scrollView.observe(\.contentSize, options: [.new]) { [weak self] sv, _ in
                self?.updateThumb(sv)
            }
            boundsObservation = scrollView.observe(\.bounds, options: [.new]) { [weak self] sv, change in
                guard change.oldValue?.size != change.newValue?.size else { return }
                self?.updateThumb(sv)
            }
            updateThumb(scrollView)
        }

        func teardown() {
            thumb?.removeFromSuperview()
            thumb = nil
            offsetObservation?.invalidate()
            sizeObservation?.invalidate()
            boundsObservation?.invalidate()
            offsetObservation = nil
            sizeObservation = nil
            boundsObservation = nil
            scrollView = nil
        }

        private func handleScroll(_ scrollView: UIScrollView) {
            updateThumb(scrollView)
            thumb?.flash()
        }

        private func updateThumb(_ scrollView: UIScrollView) {
            thumb?.update(scrollView: scrollView)
        }
    }
}

/// 进度条滑块：按内容/可视区比例确定高度与位置，滑动时淡入、停手后淡出。
private final class ChatScrollThumbView: UIView {
    private var hideWorkItem: DispatchWorkItem?
    private let hideDelay: TimeInterval = 1.1
    private let thumbWidth: CGFloat = 2.5
    private let trailingGap: CGFloat = 1.5
    private let minThumbHeight: CGFloat = 28

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(Color.holoTextSecondary).withAlphaComponent(0.35)
        layer.cornerRadius = thumbWidth / 2
        layer.zPosition = 1000   // 确保盖在 LazyVStack 内容之上
        alpha = 0
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 根据当前滚动几何刷新滑块高度与位置。
    func update(scrollView: UIScrollView) {
        let contentHeight = scrollView.contentSize.height
        let viewportHeight = scrollView.bounds.height
        guard contentHeight > viewportHeight, viewportHeight > 0 else {
            isHidden = true
            return
        }
        isHidden = false

        let insetTop = scrollView.adjustedContentInset.top
        let insetBottom = scrollView.adjustedContentInset.bottom
        let totalHeight = contentHeight + insetTop + insetBottom
        let scrollableRange = totalHeight - viewportHeight
        guard scrollableRange > 0 else { return }

        let clamped = max(0, min(scrollableRange, scrollView.contentOffset.y + insetTop))
        let ratio = min(1, viewportHeight / totalHeight)
        let height = max(minThumbHeight, viewportHeight * ratio)
        // 滑块在可视区内的相对位置（0=顶部）
        let visualY = clamped * (viewportHeight - height) / scrollableRange
        // 滑块挂在 scrollView 内，其坐标系随 contentOffset 移动，需补偿以保持视觉固定
        let originY = scrollView.contentOffset.y + insetTop + visualY
        let originX = scrollView.bounds.width - thumbWidth - trailingGap

        let newFrame = CGRect(x: originX, y: originY, width: thumbWidth, height: height)
        // frame 直接赋值本无动画，包一层 performWithoutAnimation 防止 CALayer 隐式动画
        UIView.performWithoutAnimation {
            self.frame = newFrame
        }
    }

    /// 滚动事件触发：淡入显示，并重置停手淡出的计时。
    func flash() {
        if alpha < 1 {
            UIView.animate(withDuration: 0.2) { self.alpha = 1 }
        }
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.35) { self?.alpha = 0 }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    }

    override func removeFromSuperview() {
        hideWorkItem?.cancel()
        super.removeFromSuperview()
    }
}
