//
//  SwipeActionView.swift
//  Holo
//
//  通用右滑手势组件 - 归档与删除
//  使用 UIKit 手势识别器，解决 ScrollView 内滚动冲突
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import Foundation

// MARK: - Layout Constants

private enum SwipeConstants {
    static let actionWidth: CGFloat = 70
}

private let snapAnimation = HoloAnimation.snappy

// MARK: - SwipeActionView

/// 通用左滑手势组件（露出归档/删除按钮）
/// Pan 手势挂在 window 上，通过 shouldReceiveTouch 限定在 overlay 区域内
/// overlay 的 hitTest 返回 nil → 所有触摸穿透到 SwiftUI 内容
/// window 上的 pan 手势仍可检测水平滑动
struct SwipeActionView<Content: View>: View {

    // MARK: - Properties

    let isRevealed: Binding<Bool>
    let isEnabled: Bool
    let content: Content
    /// 延期主操作（nil = 不显示延期键，如重复任务/未安排任务）
    let onPostpone: (() -> Void)?
    let onArchive: () -> Void
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var showDeleteConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 常驻模块隐藏态（HomeView ZStack opacity=0）必须同步摘除 window 手势，
    /// 避免后台 6 个常驻模块累积上百个 UIPanGestureRecognizer 拖慢全 App 每次起手滑动。
    @Environment(\.holoMotionSurfaceIsActive) private var motionSurfaceActive

    private var effectiveSwipeEnabled: Bool {
        isEnabled && motionSurfaceActive
    }

    /// 按钮数量决定展开宽度：延期(可选) + 归档 + 删除
    private var snapOpenOffset: CGFloat {
        SwipeConstants.actionWidth * (onPostpone != nil ? 3 : 2)
    }

    /// 拉出进度（0...1），驱动操作按钮随手指自然浮现而非在 -0.5pt 硬切
    private var revealProgress: CGFloat {
        min(1, max(0, -offset / max(1, snapOpenOffset)))
    }

    // MARK: - Initialization

    init(
        isRevealed: Binding<Bool>,
        isEnabled: Bool = true,
        @ViewBuilder content: () -> Content,
        onPostpone: (() -> Void)? = nil,
        onArchive: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.isRevealed = isRevealed
        self.isEnabled = isEnabled
        self.content = content()
        self.onPostpone = onPostpone
        self.onArchive = onArchive
        self.onDelete = onDelete
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .trailing) {
            actionButtons
                // 操作层常驻在内容背后；任务完成时卡片会换形成更矮的记录行，
                // 若闭合态仍参与绘制，换形中间帧会短暂露出最右侧的删除按钮。
                // 只有用户真正开始左滑后才随拉出进度浮现，避免状态动画泄露危险操作。
                .opacity(offset < -0.5 ? Double(min(1, revealProgress * 1.4)) : 0)
                .scaleEffect(reduceMotion ? 1 : (0.94 + 0.06 * revealProgress), anchor: .trailing)
                .allowsHitTesting(offset < -0.5)
                // 闭合态必须同步从无障碍树摘除（2026-09-26 R1 实锤）：opacity(0) 不摘 AX，
                // 7 张卡的归档/删除幽灵按钮常驻 AX 且 isHittable=true——VoiceOver 可聚焦
                // 看不见的按钮，XCUITest 泄露断言也被幽灵误触；AX 可见性必须与视觉一致
                .accessibilityHidden(offset >= -0.5)

            content
                .offset(x: offset)
                .overlay(
                    SwipeGestureOverlay(
                        offset: $offset,
                        isRevealed: isRevealed,
                        isEnabled: effectiveSwipeEnabled,
                        snapOffset: snapOpenOffset
                    )
                )
        }
        .onChange(of: effectiveSwipeEnabled) { _, enabled in
            guard !enabled else { return }
            close()
        }
        .onChange(of: isRevealed.wrappedValue) { _, newValue in
            withAnimation(HoloAnimation.resolved(snapAnimation, reduceMotion: reduceMotion)) {
                offset = newValue ? -snapOpenOffset : 0
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                onDelete()
            }
        } message: {
            // 单条删除已建批次进回收站（2026-09-06 拍板），30 天内可在最近删除自助恢复
            Text(String(localized: "删除后将进入回收站并保留 30 天，可在「设置 → 数据管理 → 最近删除」中恢复。"))
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 0) {
            if let onPostpone = onPostpone {
                Button {
                    onPostpone()
                    close()
                } label: {
                    VStack(spacing: 4) {
                        PostponeIcon()
                            .stroke(
                                Color.holoPrimary,
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                            )
                            .frame(width: 22, height: 22)
                        Text("延期")
                            .font(.system(size: 10))
                            .foregroundColor(Color.holoPrimary)
                    }
                    .frame(width: SwipeConstants.actionWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.holoPrimary.opacity(0.10))
                }
            }

            Button {
                onArchive()
                close()
            } label: {
                VStack(spacing: 4) {
                    ArchiveIcon()
                        .stroke(
                            Color.holoTextSecondary,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 22, height: 22)
                    Text("归档")
                        .font(.system(size: 10))
                        .foregroundColor(Color.holoTextSecondary)
                }
                .frame(width: SwipeConstants.actionWidth)
                .frame(maxHeight: .infinity)
                #if canImport(UIKit)
                .background(Color(.systemGray6))
                #else
                .background(Color(nsColor: .controlBackgroundColor))
                #endif
            }
            // 露出态标识随视觉露出翻转：闭合态幽灵按钮（opacity 0）在 iOS 26 的
            // XCUITest automation 树里仍存在且 isHittable 不可靠，手势门禁以
            // revealed 标识是否出现为准，不依赖 AX 遮挡判定
            .accessibilityIdentifier(offset < -0.5 ? "swipe-archive-revealed" : "swipe-archive")

            Button {
                showDeleteConfirmation = true
            } label: {
                VStack(spacing: 4) {
                    TrashIcon()
                        .stroke(
                            Color.holoError,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 22, height: 22)
                    Text("删除")
                        .font(.system(size: 10))
                        .foregroundColor(Color.holoError)
                }
                .frame(width: SwipeConstants.actionWidth)
                .frame(maxHeight: .infinity)
                .background(Color.red.opacity(0.08))
            }
            .accessibilityIdentifier(offset < -0.5 ? "swipe-delete-revealed" : "swipe-delete")
        }
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - Helpers

    private func close() {
        withAnimation(HoloAnimation.resolved(snapAnimation, reduceMotion: reduceMotion)) {
            offset = 0
            isRevealed.wrappedValue = false
        }
    }
}

// MARK: - UIKit 手势覆盖层

/// 透明 UIView overlay，仅用于定位触摸区域
/// hitTest 返回 nil → 所有触摸穿透到 SwiftUI 内容
/// Pan 手势挂在 window 上，通过 shouldReceiveTouch 限定在 overlay 区域
#if canImport(UIKit)
private struct SwipeGestureOverlay: UIViewRepresentable {

    @Binding var offset: CGFloat
    let isRevealed: Binding<Bool>
    let isEnabled: Bool
    let snapOffset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> SwipeOverlayView {
        let view = SwipeOverlayView()

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        context.coordinator.panGesture = pan
        context.coordinator.overlayView = view
        view.coordinator = context.coordinator

        return view
    }

    func updateUIView(_ uiView: SwipeOverlayView, context: Context) {
        context.coordinator.parent = self
        if isEnabled {
            context.coordinator.ensureGestureAttached()
            context.coordinator.panGesture?.isEnabled = true
        } else {
            context.coordinator.detachGesture()
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SwipeGestureOverlay
        var panGesture: UIPanGestureRecognizer?
        weak var overlayView: SwipeOverlayView?
        private weak var disabledScrollView: UIScrollView?
        private var gestureLock = HorizontalGestureLock()
        private var attachRetryCount = 0
        private static let maxRetryCount = 5

        init(_ parent: SwipeGestureOverlay) {
            self.parent = parent
        }

        deinit {
            if let pan = panGesture {
                pan.view?.removeGestureRecognizer(pan)
            }
        }

        /// 将 Pan 手势挂载到 window（不依赖 SwiftUI 内部 superview）
        /// 通过 shouldReceiveTouch 限定只在 overlay 区域内响应
        func ensureGestureAttached() {
            guard parent.isEnabled else {
                detachGesture()
                return
            }
            guard let pan = panGesture else { return }
            guard let window = overlayView?.window else {
                scheduleRetry()
                return
            }

            // 已挂载到 window → 跳过
            if pan.view === window { return }

            // 从旧宿主移除
            pan.view?.removeGestureRecognizer(pan)
            attachRetryCount = 0
            window.addGestureRecognizer(pan)
        }

        /// 从 window 摘除 Pan 手势（常驻模块隐藏、侧栏盖住或视图离窗时调用，防止窗口手势 O(N) 堆积）
        func detachGesture() {
            guard let pan = panGesture else { return }
            pan.isEnabled = false
            pan.view?.removeGestureRecognizer(pan)
        }

        private func scheduleRetry() {
            guard attachRetryCount < Self.maxRetryCount else { return }
            attachRetryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.ensureGestureAttached()
            }
        }

        // MARK: - Pan Handler

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            let snap = parent.snapOffset

            switch gesture.state {
            case .began:
                gestureLock.reset()

            case .changed:
                switch gestureLock.update(translation: translation) {
                case .undecided:
                    return
                case .vertical:
                    return
                case .horizontal:
                    disableScrollView(gesture)
                }

                let h = translation.x
                let baseOffset: CGFloat = parent.isRevealed.wrappedValue ? -snap : 0
                let raw = baseOffset + h
                let clamped: CGFloat
                if raw < -snap {
                    // 超出展开宽后柔顺橡皮筋阻尼（渐近最多多拉 32pt，不撞硬墙）
                    let excess = -snap - raw
                    clamped = -snap - (excess * 32) / (excess + 32)
                } else if raw > 0 {
                    clamped = 0
                } else {
                    clamped = raw
                }
                var tx = SwiftUI.Transaction(animation: nil)
                tx.disablesAnimations = true
                withTransaction(tx) {
                    parent.offset = clamped
                }

            case .ended, .cancelled:
                enableScrollView()

                let anim = UIAccessibility.isReduceMotionEnabled ? nil : snapAnimation

                // 未锁定为水平时不处理速度，避免垂直滚动结束时误开操作按钮
                if gestureLock.axis != .horizontal {
                    withAnimation(anim) {
                        parent.offset = parent.isRevealed.wrappedValue ? -snap : 0
                    }
                    gestureLock.reset()
                    return
                }

                let velocity = gesture.velocity(in: gesture.view)
                // 结合当前拖出位移 + 惯性预测：慢拖过半和快甩都能自然落位
                let projected = parent.offset + velocity.x * 0.22
                let shouldOpen: Bool
                if parent.isRevealed.wrappedValue {
                    shouldOpen = projected < -(snap - HorizontalGestureTuning.global.horizontalConfirmDistance)
                } else {
                    shouldOpen = projected < -snap * 0.45
                }

                if shouldOpen != parent.isRevealed.wrappedValue {
                    parent.isRevealed.wrappedValue = shouldOpen
                } else {
                    withAnimation(anim) {
                        parent.offset = shouldOpen ? -snap : 0
                    }
                }
                gestureLock.reset()

            default:
                break
            }
        }

        // MARK: - UIGestureRecognizerDelegate

        /// 只在 overlay 区域内的触摸才响应
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let overlay = overlayView else { return false }
            // 编辑器/弹窗盖着时不响应（window 手势摸得到弹层触摸，见 HoloWindowGestureGate）
            if HoloWindowGestureGate.isOverlayPresented(overlay.window) { return false }
            let locationInOverlay = touch.location(in: overlay)
            guard parent.isEnabled else { return false }
            guard overlay.bounds.width > 0, overlay.bounds.height > 0 else { return false }
            guard overlay.bounds.contains(locationInOverlay) else { return false }
            // 照片、标签等内层横向列表先消费自己的滑动；window 上的卡片手势
            // 若同时识别，会带动整张卡片露出归档/删除，甚至禁用外层滚动。
            return !touchIsInsideHorizontalScrollView(touch)
        }

        private func touchIsInsideHorizontalScrollView(_ touch: UITouch) -> Bool {
            var view: UIView? = touch.view
            while let current = view, current !== overlayView?.window {
                if let scrollView = current as? UIScrollView,
                   scrollView.isScrollEnabled,
                   (scrollView.alwaysBounceHorizontal ||
                    scrollView.contentSize.width > scrollView.bounds.width + 1) {
                    return true
                }
                view = current.superview
            }
            return false
        }

        /// 允许与 ScrollView 的手势同时识别
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            return true
        }

        // MARK: - ScrollView 控制

        private func disableScrollView(_ gesture: UIGestureRecognizer) {
            var view = overlayView?.superview ?? gesture.view?.superview
            while let v = view {
                if let scrollView = v as? UIScrollView {
                    scrollView.isScrollEnabled = false
                    disabledScrollView = scrollView
                    break
                }
                view = v.superview
            }
        }

        private func enableScrollView() {
            disabledScrollView?.isScrollEnabled = true
            disabledScrollView = nil
        }
    }
}

// MARK: - 透明覆盖 View

/// 透明 overlay，hitTest 始终返回 nil
/// 不拦截任何触摸，所有触摸穿透到下层 SwiftUI 内容
/// Pan 手势挂在 window 上，通过 shouldReceiveTouch 限定区域
private class SwipeOverlayView: UIView {

    weak var coordinator: SwipeGestureOverlay.Coordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 视图加入/离开 window 时同步手势挂载状态
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            coordinator?.ensureGestureAttached()
        } else {
            coordinator?.detachGesture()
        }
    }

    /// 始终返回 nil → 触摸穿透到下层 SwiftUI 内容
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return nil
    }
}
#else
/// macOS 等价实现：无 window 手势体系，直接用 SwiftUI DragGesture（鼠标拖拽场景无 ScrollView 抢手势问题）
private struct SwipeGestureOverlay: View {
    @Binding var offset: CGFloat
    let isRevealed: Binding<Bool>
    let isEnabled: Bool
    let snapOffset: CGFloat

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(isEnabled ? dragGesture : nil)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let h = value.translation.width
                if h < 0 {
                    let maxOffset = snapOffset + 20
                    let raw = max(-maxOffset, h)
                    offset = isRevealed.wrappedValue ? raw - snapOffset : raw
                } else if isRevealed.wrappedValue {
                    offset = -snapOffset + min(h, snapOffset)
                }
            }
            .onEnded { value in
                let predicted = value.predictedEndTranslation.width
                let shouldOpen = predicted < -snapOffset / 2
                withAnimation(snapAnimation) {
                    if shouldOpen != isRevealed.wrappedValue {
                        isRevealed.wrappedValue = shouldOpen
                    }
                    offset = shouldOpen ? -snapOffset : 0
                }
            }
    }
}
#endif
