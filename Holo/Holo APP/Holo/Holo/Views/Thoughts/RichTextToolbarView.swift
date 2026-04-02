//
//  RichTextToolbarView.swift
//  Holo
//
//  观点模块 - 富文本格式工具栏
//  提供加粗、斜体、下划线、颜色、列表、标签按钮
//

import SwiftUI

// MARK: - RichTextToolbarView

/// 富文本编辑格式工具栏
struct RichTextToolbarView: View {

    @Binding var content: String
    @Binding var selectedRange: NSRange
    var onTagButtonTap: (() -> Void)?

    @State private var showColorPicker: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HoloSpacing.sm) {
                boldButton
                italicButton
                underlineButton
                colorButton
                divider
                unorderedListButton
                orderedListButton
                divider
                tagButton
            }
            .padding(.horizontal, HoloSpacing.xs)
        }
        .padding(.vertical, HoloSpacing.xs)
        .sheet(isPresented: $showColorPicker) {
            ColorPickerPopover(content: $content, selectedRange: $selectedRange)
                .presentationDetents([.medium])
        }
    }

    // MARK: - 格式按钮

    /// 加粗按钮
    private var boldButton: some View {
        ToolbarButton(icon: "bold", label: "加粗") {
            MarkdownTextView.insertFormat(
                prefix: "**",
                suffix: "**",
                content: $content,
                range: $selectedRange
            )
        }
    }

    /// 斜体按钮
    private var italicButton: some View {
        ToolbarButton(icon: "italic", label: "斜体") {
            MarkdownTextView.insertFormat(
                prefix: "*",
                suffix: "*",
                content: $content,
                range: $selectedRange
            )
        }
    }

    /// 下划线按钮
    private var underlineButton: some View {
        ToolbarButton(icon: "underline", label: "下划线") {
            MarkdownTextView.insertFormat(
                prefix: "++",
                suffix: "++",
                content: $content,
                range: $selectedRange
            )
        }
    }

    /// 颜色按钮
    private var colorButton: some View {
        ToolbarButton(icon: "paintpalette", label: "颜色") {
            showColorPicker = true
        }
    }

    /// 无序列表按钮
    private var unorderedListButton: some View {
        ToolbarButton(icon: "list.bullet", label: "无序列表") {
            MarkdownTextView.insertAtLineStart(
                "- ",
                content: $content,
                range: $selectedRange
            )
        }
    }

    /// 有序列表按钮
    private var orderedListButton: some View {
        ToolbarButton(icon: "list.number", label: "有序列表") {
            MarkdownTextView.insertAtLineStart(
                "1. ",
                content: $content,
                range: $selectedRange
            )
        }
    }

    /// 标签按钮
    private var tagButton: some View {
        ToolbarButton(icon: "number", label: "标签") {
            MarkdownTextView.insertFormat(
                prefix: "#",
                suffix: "",
                content: $content,
                range: $selectedRange
            )
            onTagButtonTap?()
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
    let action: () -> Void

    @State private var isPressed: Bool = false

    var body: some View {
        Button(action: {
            HapticManager.light()
            action()
        }) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 36, height: 28)
            }
        }
        .accessibilityLabel(label)
    }
}
