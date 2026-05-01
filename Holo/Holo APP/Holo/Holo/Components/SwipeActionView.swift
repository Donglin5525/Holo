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
/// 使用 UIKit UIPanGestureRecognizer，直接挂在 overlay 自身上
/// hitTest 返回 self + cancelsTouchesInView = false：
/// - 手势直接接收触摸
/// - SwiftUI Button / onTapGesture 正常响应点击
/// 方向判断在 .changed 中用 translation 确认（比 velocity 更可靠）
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

/// 透明 UIView overlay，承载 UIPanGestureRecognizer
/// hitTest 返回 self 让手势直接接收触摸
/// cancelsTouchesInView = false 确保 SwiftUI Button 正常响应
private struct SwipeGestureOverlay: UIViewRepresentable {

    @Binding var offset: CGFloat
    let isRevealed: Binding<Bool>

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> SwipeOverlayView {
        let view = SwipeOverlayView()

        // Pan 手势直接挂在 overlay 自身上（不依赖 superview）
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false  // 不吞掉触摸，SwiftUI Button 正常响应
        view.addGestureRecognizer(pan)
        context.coordinator.panGesture = pan

        return view
    }

    func updateUIView(_ uiView: SwipeOverlayView, context: Context) {
        context.coordinator.parent = self
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SwipeGestureOverlay
        var panGesture: UIPanGestureRecognizer?
        private weak var disabledScrollView: UIScrollView?
        /// 手势方向是否已确认为水平
        private var isHorizontalConfirmed = false

        init(_ parent: SwipeGestureOverlay) {
            self.parent = parent
        }

        deinit {
            if let pan = panGesture {
                pan.view?.removeGestureRecognizer(pan)
            }
        }

        // MARK: - Pan Handler

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            let snap = SwipeConstants.snapOpenOffset

            switch gesture.state {
            case .began:
                isHorizontalConfirmed = false
                // 不在这里禁用 ScrollView，等方向确认后再禁用

            case .changed:
                // 首次收到位移时判断方向
                if !isHorizontalConfirmed {
                    let h = abs(translation.x)
                    let v = abs(translation.y)
                    // 水平位移 > 垂直位移 且 超过最小阈值 → 确认为水平滑动
                    if h > v && h > SwipeConstants.minimumDragDistance {
                        isHorizontalConfirmed = true
                        // 方向确认为水平，此时才禁用 ScrollView
                        disableScrollView(gesture)
                    } else if v > h && v > SwipeConstants.minimumDragDistance {
                        // 垂直滑动 → 取消手势，让 ScrollView 处理（不需要恢复，因为没有禁用）
                        gesture.state = .cancelled
                        return
                    } else {
                        // 位移太小，继续等待
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

/// 透明 overlay，承载 UIPanGestureRecognizer
/// hitTest 返回 self 让手势直接接收触摸
/// cancelsTouchesInView = false 确保 SwiftUI Button / onTapGesture 正常响应
private class SwipeOverlayView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 返回 self 让 pan 手势直接接收触摸
    /// 配合 cancelsTouchesInView = false，SwiftUI 点击事件不被吞掉
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return self
    }
}
