//
//  RichTextToolbarView.swift
//  Holo
//
//  观点模块 - 富文本格式工具栏
//  提供加粗、无序列表、有序列表按钮
//

import SwiftUI

// MARK: - RichTextToolbarView

/// 富文本编辑格式工具栏
struct RichTextToolbarView: View {

    @Binding var pendingAction: MarkdownEditorAction?
    var formatState: TypingFormatState = TypingFormatState()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HoloSpacing.sm) {
                boldButton
                divider
                unorderedListButton
                orderedListButton
            }
            .padding(.horizontal, HoloSpacing.xs)
        }
        .padding(.vertical, HoloSpacing.xs)
    }

    // MARK: - 格式按钮

    /// 加粗按钮
    private var boldButton: some View {
        ToolbarButton(icon: "bold", label: "加粗", isActive: formatState.isBold) {
            pendingAction = .toggleBold
        }
    }

    /// 无序列表按钮
    private var unorderedListButton: some View {
        ToolbarButton(icon: "list.bullet", label: "无序列表") {
            pendingAction = .insertUnorderedList
        }
    }

    /// 有序列表按钮
    private var orderedListButton: some View {
        ToolbarButton(icon: "list.number", label: "有序列表") {
            pendingAction = .insertOrderedList
        }
    }

    /// 分隔线
    private var divider: some View {
        Rectangle()
            .fill(Color.holoBorder)
            .frame(width: 1, height: 24)
            .padding(.horizontal, 2)
    }
}

// MARK: - ToolbarButton

/// 工具栏按钮组件
private struct ToolbarButton: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: {
            HapticManager.light()
            action()
        }) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: isActive ? .bold : .medium))
                    .foregroundColor(isActive ? .holoPrimary : .holoTextPrimary)
                    .frame(width: 36, height: 28)
            }
        }
        .accessibilityLabel(label)
    }
}
