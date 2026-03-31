//
//  SwipeActionView.swift
//  Holo
//
//  通用右滑手势组件 - 归档与删除
//

import SwiftUI

// MARK: - Layout Constants

private enum SwipeConstants {
    static let actionWidth: CGFloat = 70
    static let snapOpenOffset: CGFloat = 140
    static let minimumDragDistance: CGFloat = 10
}

private let snapAnimation = Animation.spring(response: 0.3, dampingFraction: 0.8)

// MARK: - SwipeActionView

/// 通用右滑手势组件
/// 滑动后显示归档和删除两个操作按钮
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
                .gesture(dragGesture)
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

    // MARK: - Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: SwipeConstants.minimumDragDistance)
            .onChanged { value in
                let h = value.translation.width
                let v = abs(value.translation.height)

                // 水平位移需略大于垂直，防止误触 ScrollView
                guard abs(h) > v * 1.2 else { return }

                if h < 0 {
                    // 左滑：展开或继续展开
                    let maxOffset = SwipeConstants.snapOpenOffset + 20
                    let raw = max(-maxOffset, h)
                    offset = isRevealed.wrappedValue
                        ? raw - SwipeConstants.snapOpenOffset
                        : raw
                } else if isRevealed.wrappedValue {
                    // 右滑收回
                    offset = -SwipeConstants.snapOpenOffset + min(h, SwipeConstants.snapOpenOffset)
                }
            }
            .onEnded { value in
                let h = value.translation.width
                let v = abs(value.translation.height)

                // 非水平滑动 → 弹回原位
                guard abs(h) > v * 1.2 else {
                    snapBack()
                    return
                }

                let shouldOpen: Bool
                if isRevealed.wrappedValue {
                    shouldOpen = value.predictedEndTranslation.width < -SwipeConstants.minimumDragDistance
                } else {
                    shouldOpen = value.predictedEndTranslation.width < -SwipeConstants.snapOpenOffset / 2
                }

                let targetOffset: CGFloat = shouldOpen ? -SwipeConstants.snapOpenOffset : 0

                if shouldOpen != isRevealed.wrappedValue {
                    // 状态切换 → 由 onChange 统一处理动画，避免双重弹簧
                    isRevealed.wrappedValue = shouldOpen
                } else {
                    // 状态未变 → 自己弹回
                    withAnimation(snapAnimation) {
                        offset = targetOffset
                    }
                }
            }
    }

    // MARK: - Helpers

    private func close() {
        withAnimation(snapAnimation) {
            offset = 0
            isRevealed.wrappedValue = false
        }
    }

    private func snapBack() {
        withAnimation(snapAnimation) {
            offset = isRevealed.wrappedValue ? -SwipeConstants.snapOpenOffset : 0
        }
    }
}
