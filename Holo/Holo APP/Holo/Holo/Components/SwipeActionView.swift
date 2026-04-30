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

/// 通用右滑手势组件
/// 使用 UIKit UIPanGestureRecognizer 实现方向感知
/// 垂直方向：手势不拦截，ScrollView 正常滚动
/// 水平方向：独占手势，显示操作按钮
///
/// 触摸穿透设计：
/// - overlay 的 hitTest 返回 nil → 所有触摸穿透到 SwiftUI 内容
/// - Pan 手势挂在父视图上 → 仍可检测水平滑动
/// - SwiftUI Button / onTapGesture 正常响应点击
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

/// 透明 UIView overlay，仅负责将 Pan 手势挂载到父视图
/// overlay 本身 hitTest 返回 nil，不拦截任何触摸
/// SwiftUI 的 Button / onTapGesture 可以正常响应
private struct SwipeGestureOverlay: UIViewRepresentable {

    @Binding var offset: CGFloat
    let isRevealed: Binding<Bool>

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> SwipeOverlayView {
        let view = SwipeOverlayView()

        // Pan 手势
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        context.coordinator.panGesture = pan

        // 将 pan 手势和 overlay 引用存到 coordinator
        context.coordinator.overlayView = view

        // 视图加入层级后再挂载手势，避免 superview 为 nil
        let coordinator = context.coordinator
        view.onMovedToSuperview = { [weak coordinator] in
            coordinator?.attachPanGesture()
        }

        return view
    }

    func updateUIView(_ uiView: SwipeOverlayView, context: Context) {
        context.coordinator.parent = self
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SwipeGestureOverlay
        var panGesture: UIPanGestureRecognizer?
        weak var overlayView: SwipeOverlayView?
        private weak var disabledScrollView: UIScrollView?

        init(_ parent: SwipeGestureOverlay) {
            self.parent = parent
        }

        deinit {
            if let pan = panGesture {
                pan.view?.removeGestureRecognizer(pan)
            }
        }

        /// 将 Pan 手势挂载到 overlay 的父视图
        func attachPanGesture() {
            guard let pan = panGesture,
                  pan.view == nil,  // 尚未挂载
                  let superview = overlayView?.superview else { return }

            superview.addGestureRecognizer(pan)
        }

        // MARK: - Pan Handler

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            let snap = SwipeConstants.snapOpenOffset

            switch gesture.state {
            case .began:
                disableScrollView(gesture)

            case .changed:
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

        /// 控制手势是否开始：只在水平方向时返回 true
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            return abs(velocity.x) > abs(velocity.y)
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
/// 不拦截任何触摸，所有触摸穿透到 SwiftUI 内容层
private class SwipeOverlayView: UIView {
    var onMovedToSuperview: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview != nil {
            onMovedToSuperview?()
        }
    }

    /// 始终返回 nil → 触摸穿透到下层 SwiftUI 内容
    /// SwiftUI 的 Button / onTapGesture 正常接收触摸
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return nil
    }
}
