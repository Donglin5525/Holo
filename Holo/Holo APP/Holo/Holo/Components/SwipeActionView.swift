//
//  SwipeActionView.swift
//  Holo
//
//  通用右滑手势组件 - 归档与删除
//  使用 UIKit 手势识别器，解决 ScrollView 内滚动冲突
//

import SwiftUI
import UIKit

// MARK: - Layout Constants

private enum SwipeConstants {
    static let actionWidth: CGFloat = 70
    static let snapOpenOffset: CGFloat = 140
    static let minimumDragDistance: CGFloat = 10
}

private let snapAnimation = Animation.spring(response: 0.3, dampingFraction: 0.8)

// MARK: - SwipeActionView

/// 通用左滑手势组件（露出归档/删除按钮）
/// Pan 手势挂在 window 上，通过 shouldReceiveTouch 限定在 overlay 区域内
/// overlay 的 hitTest 返回 nil → 所有触摸穿透到 SwiftUI 内容
/// window 上的 pan 手势仍可检测水平滑动
struct SwipeActionView<Content: View>: View {

    // MARK: - Properties

    let isRevealed: Binding<Bool>
    let content: Content
    let onArchive: () -> Void
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var showDeleteConfirmation = false

    // MARK: - Initialization

    init(
        isRevealed: Binding<Bool>,
        @ViewBuilder content: () -> Content,
        onArchive: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.isRevealed = isRevealed
        self.content = content()
        self.onArchive = onArchive
        self.onDelete = onDelete
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .trailing) {
            actionButtons

            content
                .offset(x: offset)
                .overlay(
                    SwipeGestureOverlay(
                        offset: $offset,
                        isRevealed: isRevealed
                    )
                )
        }
        .onChange(of: isRevealed.wrappedValue) { _, newValue in
            withAnimation(snapAnimation) {
                offset = newValue ? -SwipeConstants.snapOpenOffset : 0
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("此操作不可撤销，确定要删除吗？")
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 0) {
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
                .background(Color(.systemGray6))
            }

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
        }
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - Helpers

    private func close() {
        withAnimation(snapAnimation) {
            offset = 0
            isRevealed.wrappedValue = false
        }
    }
}

// MARK: - UIKit 手势覆盖层

/// 透明 UIView overlay，仅用于定位触摸区域
/// hitTest 返回 nil → 所有触摸穿透到 SwiftUI 内容
/// Pan 手势挂在 window 上，通过 shouldReceiveTouch 限定在 overlay 区域
private struct SwipeGestureOverlay: UIViewRepresentable {

    @Binding var offset: CGFloat
    let isRevealed: Binding<Bool>

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
        context.coordinator.ensureGestureAttached()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SwipeGestureOverlay
        var panGesture: UIPanGestureRecognizer?
        weak var overlayView: SwipeOverlayView?
        private weak var disabledScrollView: UIScrollView?
        private var isHorizontalConfirmed = false
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
            let snap = SwipeConstants.snapOpenOffset

            switch gesture.state {
            case .began:
                isHorizontalConfirmed = false

            case .changed:
                if !isHorizontalConfirmed {
                    let h = abs(translation.x)
                    let v = abs(translation.y)
                    if h > v && h > SwipeConstants.minimumDragDistance {
                        isHorizontalConfirmed = true
                        disableScrollView(gesture)
                    } else if v > h && v > SwipeConstants.minimumDragDistance {
                        gesture.state = .cancelled
                        return
                    } else {
                        return
                    }
                }
                let h = translation.x
                if h < 0 {
                    let maxOffset = snap + 20
                    let raw = max(-maxOffset, h)
                    parent.offset = parent.isRevealed.wrappedValue
                        ? raw - snap
                        : raw
                } else if parent.isRevealed.wrappedValue {
                    parent.offset = -snap + min(h, snap)
                }

            case .ended, .cancelled:
                enableScrollView()

                let velocity = gesture.velocity(in: gesture.view)
                let predicted = velocity.x * 0.3

                let shouldOpen: Bool
                if parent.isRevealed.wrappedValue {
                    shouldOpen = predicted < -SwipeConstants.minimumDragDistance
                } else {
                    shouldOpen = predicted < -snap / 2
                }

                if shouldOpen != parent.isRevealed.wrappedValue {
                    parent.isRevealed.wrappedValue = shouldOpen
                } else {
                    withAnimation(snapAnimation) {
                        parent.offset = shouldOpen ? -snap : 0
                    }
                }

            default:
                break
            }
        }

        // MARK: - UIGestureRecognizerDelegate

        /// 只在 overlay 区域内的触摸才响应
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let overlay = overlayView else { return false }
            guard overlay.bounds.width > 0, overlay.bounds.height > 0 else { return false }
            let location = touch.location(in: overlay)
            return overlay.bounds.contains(location)
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
            var view = gesture.view?.superview
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

    /// 视图加入 window 时触发手势挂载
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            coordinator?.ensureGestureAttached()
        }
    }

    /// 始终返回 nil → 触摸穿透到下层 SwiftUI 内容
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return nil
    }
}
