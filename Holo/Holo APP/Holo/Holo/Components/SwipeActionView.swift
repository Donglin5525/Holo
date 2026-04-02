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
struct SwipeActionView<Content: View>: View {

    // MARK: - Properties

    let isRevealed: Binding<Bool>
    let content: Content
    let onArchive: () -> Void
    let onDelete: () -> Void
    var onTap: (() -> Void)?

    @State private var offset: CGFloat = 0
    @State private var showDeleteConfirmation = false

    // MARK: - Initialization

    init(
        isRevealed: Binding<Bool>,
        @ViewBuilder content: () -> Content,
        onArchive: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onTap: (() -> Void)? = nil
    ) {
        self.isRevealed = isRevealed
        self.content = content()
        self.onArchive = onArchive
        self.onDelete = onDelete
        self.onTap = onTap
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
                        isRevealed: isRevealed,
                        onTap: onTap
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

/// 透明 UIView overlay，承载方向感知的 Pan 手势
/// 通过 Coordinator 的 gestureRecognizerShouldBegin 控制方向
/// 垂直方向 → 手势不启动 → ScrollView 正常滚动
/// 水平方向 → 手势启动 → 临时禁用 ScrollView → 处理偏移
private struct SwipeGestureOverlay: UIViewRepresentable {

    @Binding var offset: CGFloat
    let isRevealed: Binding<Bool>
    let onTap: (() -> Void)?

    func makeUIView(context: Context) -> SwipeOverlayView {
        let view = SwipeOverlayView()

        // Tap 手势
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        // Pan 手势（方向由 delegate 控制）
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        context.coordinator.panGesture = pan

        return view
    }

    func updateUIView(_ uiView: SwipeOverlayView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SwipeGestureOverlay
        weak var panGesture: UIPanGestureRecognizer?
        private weak var disabledScrollView: UIScrollView?

        init(_ parent: SwipeGestureOverlay) {
            self.parent = parent
        }

        // MARK: - Tap

        @objc func handleTap() {
            parent.onTap?()
        }

        // MARK: - Pan

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

        /// 关键方法：控制手势是否开始
        /// 检查初始速度方向，只在水平方向时返回 true
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            // 只有水平方向速度大于垂直方向时才开始手势
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

private class SwipeOverlayView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
