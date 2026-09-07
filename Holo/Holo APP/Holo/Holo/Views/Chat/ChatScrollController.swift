//
//  ChatScrollController.swift
//  Holo
//
//  成熟 IM 风格的 UIScrollView 协调层：
//  - prepend 历史消息时按真实 contentSize 增量保持像素位置
//  - 仅在用户原本位于底部时跟随流式内容增长
//  - 为任意距离提供可靠的回到底部能力
//  - 内容缩短、键盘变化后把偏移限制在合法范围
//

import SwiftUI
import UIKit
import Combine

final class ChatScrollController: ObservableObject {

    @Published private(set) var viewport: ChatScrollViewportState = .initial

    private weak var scrollView: UIScrollView?
    private var contentOffsetObservation: NSKeyValueObservation?
    private var contentSizeObservation: NSKeyValueObservation?
    private var boundsObservation: NSKeyValueObservation?
    private var isPreservingPrepend = false
    private var prependFinishWorkItem: DispatchWorkItem?
    private var isClampPending = false
    private var isBottomPinActive = false
    private var bottomPinUsesAnimation = false
    private var bottomPinFinishWorkItem: DispatchWorkItem?
    private var isAdjustingOffset = false
    private var interactionSequence = 0
    private var settlingPolicy = ChatOffsetSettlingPolicy()
    private var settleDisplayLink: CADisplayLink?

    /// 顶部提前约半屏开始取下一页，数据通常能在用户真正到顶前准备好。
    private let topPrefetchDistance: CGFloat = 260
    /// 底部小范围内容增长继续自然跟随，超过后视为用户主动浏览历史。
    private let bottomFollowDistance: CGFloat = 72
    /// 离开底部一段明显距离才显示入口，避免按钮在轻微回弹时闪烁。
    private let jumpButtonDistance: CGFloat = 180

    deinit {
        detach()
    }

    func attach(to candidate: UIScrollView) {
        guard scrollView !== candidate else { return }

        let shouldRestoreBottomPin = isBottomPinActive
        let restoredBottomPinAnimation = bottomPinUsesAnimation
        detach()
        isBottomPinActive = shouldRestoreBottomPin
        bottomPinUsesAnimation = restoredBottomPinAnimation
        scrollView = candidate
        candidate.panGestureRecognizer.addTarget(
            self,
            action: #selector(handlePanGesture(_:))
        )

        contentOffsetObservation = candidate.observe(
            \.contentOffset,
            options: [.new]
        ) { [weak self] scrollView, _ in
            if scrollView.isTracking || scrollView.isDragging {
                self?.cancelBottomPin()
            }
            self?.updateViewport(in: scrollView)
        }

        contentSizeObservation = candidate.observe(
            \.contentSize,
            options: [.old, .new]
        ) { [weak self] scrollView, change in
            self?.handleContentSizeChange(
                in: scrollView,
                oldSize: change.oldValue ?? scrollView.contentSize,
                newSize: change.newValue ?? scrollView.contentSize
            )
        }

        boundsObservation = candidate.observe(
            \.bounds,
            options: [.old, .new]
        ) { [weak self] scrollView, change in
            guard change.oldValue?.size != change.newValue?.size else { return }
            self?.handleViewportSizeChange(in: scrollView)
        }

        if isBottomPinActive {
            scheduleBottomPinFinish(after: 0.45)
        }
        // updateViewport 内部已统一异步发布 viewport，此处可直接同步调用；
        // 但 pinToCurrentBottomIfNeeded 涉及修改 contentOffset，若 attach 恰好落在
        // View update 周期，仍需跳出一帧以避免同步驱动布局。
        DispatchQueue.main.async { [weak self, weak candidate] in
            guard let self, let candidate else { return }
            self.updateViewport(in: candidate)
            self.pinToCurrentBottomIfNeeded(in: candidate)
        }
    }

    func detach() {
        scrollView?.panGestureRecognizer.removeTarget(
            self,
            action: #selector(handlePanGesture(_:))
        )
        contentOffsetObservation?.invalidate()
        contentSizeObservation?.invalidate()
        boundsObservation?.invalidate()
        contentOffsetObservation = nil
        contentSizeObservation = nil
        boundsObservation = nil
        scrollView = nil
        prependFinishWorkItem?.cancel()
        prependFinishWorkItem = nil
        bottomPinFinishWorkItem?.cancel()
        bottomPinFinishWorkItem = nil
        stopOffsetSettling()
        isPreservingPrepend = false
        isBottomPinActive = false
        isClampPending = false
    }

    /// 在消息数组已经 prepend、但 SwiftUI 尚未完成新布局时调用；
    /// 之后每一次真实高度增长都会同步补偿 offset。
    func beginPreservingPrepend() {
        prependFinishWorkItem?.cancel()
        prependFinishWorkItem = nil
        isPreservingPrepend = true
    }

    /// LazyVStack 可能分多帧修正高度，因此等待最后一次 contentSize 变化稳定后再结束。
    func endPreservingPrependAfterLayout() {
        schedulePrependFinish(after: 0.4)
    }

    func scrollToBottom(animated: Bool) {
        isBottomPinActive = true
        bottomPinUsesAnimation = animated
        guard let scrollView else { return }
        scheduleBottomPinFinish(after: 0.45)
        pinToCurrentBottomIfNeeded(in: scrollView, initialAnimation: animated)
    }

    func requestOffsetClamp() {
        isClampPending = true
        beginOffsetSettling()
        guard let scrollView else { return }

        DispatchQueue.main.async { [weak self, weak scrollView] in
            guard let self, let scrollView else { return }
            scrollView.layoutIfNeeded()
            if self.clampOffset(in: scrollView) {
                self.isClampPending = false
            }
        }
    }

    /// 内容大幅收缩（卡片收起、消息删除）后开启逐帧稳定校验窗口。
    /// 一次性钳制会被 isAdjustingOffset 重入保护丢事件，也可能早于
    /// defaultScrollAnchor 的框架级再定位；只有逐帧核对最终不变量能兜住。
    func beginOffsetSettling() {
        settlingPolicy = ChatOffsetSettlingPolicy()
        guard settleDisplayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleSettleTick))
        link.add(to: .main, forMode: .common)
        settleDisplayLink = link
    }

    private func stopOffsetSettling() {
        settleDisplayLink?.invalidate()
        settleDisplayLink = nil
    }

    @objc
    private func handleSettleTick() {
        guard let scrollView else {
            stopOffsetSettling()
            return
        }
        let isUserInteracting = scrollView.isTracking
            || scrollView.isDragging
            || scrollView.isDecelerating
        // 用户拖动期间不与手指抢位置，只重置稳定计数；松手后自会回弹到合法范围。
        let didClamp = isUserInteracting ? false : clampOffset(in: scrollView)
        settlingPolicy.advance(needClamp: didClamp, isUserInteracting: isUserInteracting)
        if settlingPolicy.isFinished {
            stopOffsetSettling()
        }
    }

    // MARK: - Content changes

    private func handleContentSizeChange(
        in scrollView: UIScrollView,
        oldSize: CGSize,
        newSize: CGSize
    ) {
        guard !isAdjustingOffset else { return }

        let heightDelta = newSize.height - oldSize.height

        if isPreservingPrepend, abs(heightDelta) > 0.5 {
            // 新内容插到顶部后，把 offset 增加同样的高度；用户眼前的文字保持在同一像素。
            setOffset(
                CGPoint(
                    x: scrollView.contentOffset.x,
                    y: ChatScrollGeometry.offsetPreservingViewport(
                        currentOffsetY: scrollView.contentOffset.y,
                        prependedHeight: heightDelta
                    )
                ),
                in: scrollView,
                animated: false
            )
            schedulePrependFinish(after: 0.4)
        } else if isBottomPinActive {
            // 回底请求发生后，新消息可能下一帧才完成布局；稳定前始终追踪最新 maxY。
            pinToCurrentBottomIfNeeded(
                in: scrollView,
                initialAnimation: bottomPinUsesAnimation && !viewport.isNearBottom
            )
            scheduleBottomPinFinish(after: 0.45)
        } else if heightDelta > 0.5,
                  wasPinnedToBottom(
                    offsetY: scrollView.contentOffset.y,
                    contentHeight: oldSize.height,
                    in: scrollView
                  ),
                  !scrollView.isTracking,
                  !scrollView.isDragging,
                  !scrollView.isDecelerating {
            // 流式回复增长时不启动重复动画，直接跟随真实底部，避免动画队列互相追赶。
            setOffset(
                CGPoint(
                    x: scrollView.contentOffset.x,
                    y: maximumOffsetY(contentHeight: newSize.height, in: scrollView)
                ),
                in: scrollView,
                animated: false
            )
        } else if heightDelta < -0.5 {
            // 卡片收起或消息删除后主动修正越界，避免出现整屏空白。
            // LazyVStack 会分多帧继续收缩，KVO 也可能被重入保护丢弃，
            // 因此立即钳制之外再开逐帧校验窗口兜底。
            _ = clampOffset(in: scrollView)
            beginOffsetSettling()
        }

        if isClampPending, clampOffset(in: scrollView) {
            isClampPending = false
        }
        updateViewport(in: scrollView)
    }

    private func handleViewportSizeChange(in scrollView: UIScrollView) {
        guard !isAdjustingOffset else { return }

        // 键盘出现/消失导致可视高度变化：底部用户继续贴底，历史浏览用户保持原位置。
        if viewport.isNearBottom,
           !scrollView.isTracking,
           !scrollView.isDragging {
            setOffset(
                CGPoint(
                    x: scrollView.contentOffset.x,
                    y: maximumOffsetY(contentHeight: scrollView.contentSize.height, in: scrollView)
                ),
                in: scrollView,
                animated: false
            )
        } else {
            _ = clampOffset(in: scrollView)
        }
        updateViewport(in: scrollView)
    }

    // MARK: - Offset operations

    private func pinToCurrentBottomIfNeeded(
        in scrollView: UIScrollView,
        initialAnimation: Bool? = nil
    ) {
        guard isBottomPinActive else { return }

        scrollView.layoutIfNeeded()
        let target = CGPoint(
            x: scrollView.contentOffset.x,
            y: maximumOffsetY(contentHeight: scrollView.contentSize.height, in: scrollView)
        )
        let distance = abs(target.y - scrollView.contentOffset.y)
        let shouldAnimate = (initialAnimation ?? false)
            && ChatScrollGeometry.shouldAnimateJumpToBottom(
                distance: distance,
                viewportHeight: scrollView.bounds.height
            )

        // 动画请求只允许消费一次。后续 LazyVStack 若继续修正 contentSize，
        // 直接贴合新底部，不能重新启动动画并把一次点击拖成几十秒。
        bottomPinUsesAnimation = false
        setOffset(
            target,
            in: scrollView,
            animated: shouldAnimate
        )
    }

    private func setOffset(_ proposed: CGPoint, in scrollView: UIScrollView, animated: Bool) {
        let inset = scrollView.adjustedContentInset
        let minimumY = -inset.top
        let maximumY = maximumOffsetY(contentHeight: scrollView.contentSize.height, in: scrollView)
        let target = CGPoint(
            x: proposed.x,
            y: min(max(proposed.y, minimumY), maximumY)
        )

        guard abs(target.y - scrollView.contentOffset.y) > 0.5 else {
            updateViewport(in: scrollView)
            return
        }

        isAdjustingOffset = true
        if animated {
            scrollView.setContentOffset(target, animated: true)
        } else {
            UIView.performWithoutAnimation {
                scrollView.setContentOffset(target, animated: false)
                scrollView.layoutIfNeeded()
            }
        }
        isAdjustingOffset = false
        updateViewport(in: scrollView)
    }

    @discardableResult
    private func clampOffset(in scrollView: UIScrollView) -> Bool {
        let inset = scrollView.adjustedContentInset
        let minimumX = -inset.left
        let minimumY = -inset.top
        let maximumX = max(
            minimumX,
            scrollView.contentSize.width - scrollView.bounds.width + inset.right
        )
        let maximumY = maximumOffsetY(contentHeight: scrollView.contentSize.height, in: scrollView)
        let current = scrollView.contentOffset
        let clamped = CGPoint(
            x: min(max(current.x, minimumX), maximumX),
            y: min(max(current.y, minimumY), maximumY)
        )

        guard abs(clamped.x - current.x) > 0.5
                || abs(clamped.y - current.y) > 0.5 else {
            return false
        }

        setOffset(clamped, in: scrollView, animated: false)
        return true
    }

    private func maximumOffsetY(contentHeight: CGFloat, in scrollView: UIScrollView) -> CGFloat {
        let inset = scrollView.adjustedContentInset
        return ChatScrollGeometry.maximumOffsetY(
            contentHeight: contentHeight,
            viewportHeight: scrollView.bounds.height,
            topInset: inset.top,
            bottomInset: inset.bottom
        )
    }

    private func wasPinnedToBottom(
        offsetY: CGFloat,
        contentHeight: CGFloat,
        in scrollView: UIScrollView
    ) -> Bool {
        ChatScrollGeometry.isPinnedToBottom(
            currentOffsetY: offsetY,
            maximumOffsetY: maximumOffsetY(
                contentHeight: contentHeight,
                in: scrollView
            ),
            threshold: bottomFollowDistance
        )
    }

    // MARK: - State publishing

    @objc
    private func handlePanGesture(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began {
            interactionSequence &+= 1
            cancelBottomPin()
        }
        if let scrollView {
            updateViewport(in: scrollView)
        }
    }

    private func updateViewport(in scrollView: UIScrollView) {
        let inset = scrollView.adjustedContentInset
        let minimumY = -inset.top
        let maximumY = maximumOffsetY(contentHeight: scrollView.contentSize.height, in: scrollView)
        let distanceToTop = max(0, scrollView.contentOffset.y - minimumY)
        let distanceToBottom = max(0, maximumY - scrollView.contentOffset.y)

        let next = ChatScrollViewportState(
            isNearTop: distanceToTop <= topPrefetchDistance,
            isNearBottom: distanceToBottom <= bottomFollowDistance,
            showsJumpToLatest: distanceToBottom > jumpButtonDistance,
            isUserInteracting: scrollView.isTracking
                || scrollView.isDragging
                || scrollView.isDecelerating,
            interactionSequence: interactionSequence
        )

        guard next != viewport else { return }
        // viewport 的发布统一异步跳出一帧，确保永远不会落在 SwiftUI 的 View update
        // 周期内同步触发 objectWillChange（否则会触发"Publishing changes from within
        // view updates is not allowed"警告）。所有调用 updateViewport 的路径
        // （KVO contentOffset/contentSize、bounds、pan 手势、setOffset、attach）
        // 都经由这里收敛，一处异步化即可全覆盖。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard next != self.viewport else { return }
            self.viewport = next
        }
    }

    private func schedulePrependFinish(after delay: TimeInterval) {
        prependFinishWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.isPreservingPrepend = false
            self?.prependFinishWorkItem = nil
        }
        prependFinishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleBottomPinFinish(after delay: TimeInterval) {
        bottomPinFinishWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.isBottomPinActive = false
            self?.bottomPinFinishWorkItem = nil
        }
        bottomPinFinishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelBottomPin() {
        bottomPinFinishWorkItem?.cancel()
        bottomPinFinishWorkItem = nil
        isBottomPinActive = false
    }
}

/// 放在 SwiftUI ScrollView 内容中，自动找到祖先 UIScrollView 并交给协调器。
struct ChatScrollViewBridge: UIViewRepresentable {
    let controller: ChatScrollController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        context.coordinator.controller = controller
        attachIfPossible(from: view, controller: controller)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.controller = controller
        attachIfPossible(from: uiView, controller: controller)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.controller?.detach()
    }

    private func attachIfPossible(
        from view: UIView,
        controller: ChatScrollController
    ) {
        if let scrollView = enclosingScrollView(from: view) {
            controller.attach(to: scrollView)
            return
        }

        DispatchQueue.main.async { [weak view, weak controller] in
            guard let view, let controller,
                  let scrollView = enclosingScrollView(from: view) else { return }
            controller.attach(to: scrollView)
        }
    }

    final class Coordinator {
        weak var controller: ChatScrollController?

        init(controller: ChatScrollController) {
            self.controller = controller
        }
    }

    private func enclosingScrollView(from view: UIView) -> UIScrollView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
    }
}
