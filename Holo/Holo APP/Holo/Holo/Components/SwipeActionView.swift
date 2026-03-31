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
    static let minimumDragDistance: CGFloat = 20
}

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
            // 底层：操作按钮
            actionButtons

            // 上层：卡片内容（带偏移）
            content
                .offset(x: offset)
                .gesture(dragGesture)
                .onTapGesture {
                    if isRevealed.wrappedValue {
                        close()
                    }
                }
        }
        .onChange(of: isRevealed.wrappedValue) { _, newValue in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
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
            // 归档按钮
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

            // 删除按钮
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
                let horizontalAmount = value.translation.width
                let verticalAmount = abs(value.translation.height)

                guard abs(horizontalAmount) > verticalAmount * 1.5 else { return }

                if horizontalAmount < 0 {
                    let maxOffset = SwipeConstants.snapOpenOffset + 20
                    let newOffset = max(-maxOffset, horizontalAmount)
                    offset = isRevealed.wrappedValue
                        ? newOffset - SwipeConstants.snapOpenOffset
                        : newOffset
                } else if isRevealed.wrappedValue && horizontalAmount > 0 {
                    offset = -SwipeConstants.snapOpenOffset + min(horizontalAmount, SwipeConstants.snapOpenOffset)
                }
            }
            .onEnded { value in
                let horizontalAmount = value.translation.width
                let verticalAmount = abs(value.translation.height)

                guard abs(horizontalAmount) > verticalAmount * 1.5 else {
                    snapBack()
                    return
                }

                let shouldOpen: Bool
                if isRevealed.wrappedValue {
                    shouldOpen = value.predictedEndTranslation.width < -SwipeConstants.minimumDragDistance
                } else {
                    shouldOpen = value.predictedEndTranslation.width < -SwipeConstants.snapOpenOffset / 2
                }

                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    if shouldOpen {
                        offset = -SwipeConstants.snapOpenOffset
                        isRevealed.wrappedValue = true
                    } else {
                        offset = 0
                        isRevealed.wrappedValue = false
                    }
                }
            }
    }

    // MARK: - Helpers

    private func close() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            offset = 0
            isRevealed.wrappedValue = false
        }
    }

    private func snapBack() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            offset = isRevealed.wrappedValue ? -SwipeConstants.snapOpenOffset : 0
        }
    }
}
