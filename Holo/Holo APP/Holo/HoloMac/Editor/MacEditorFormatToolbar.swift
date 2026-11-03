//
//  MacEditorFormatToolbar.swift
//  HoloMac
//
//  想法模块 Mac 编辑器格式工具条（Phase C）
//
//  能力清单逐项对齐 iOS EditorFormatToolbar：# 标签 / @ 引用 / 插入图片 /
//  加粗 / 斜体 / 下划线 / 文字颜色 / 无序列表 / 有序列表 / 完成键；
//  快捷键 ⌘B ⌘I ⌘U 由 MacEditorTextView.performKeyEquivalent 接管，
//  与工具栏按钮走同一条 MarkdownEditorAction 管线。
//  Mac 不做：语音输入（iOS 依赖 AVAudioSession）、相机。
//  Phase E：新增「…」更多操作菜单（转为任务，经 .convertToTask 动作管线）。
//  「…」菜单另承载「删除想法」（仅已落库会话显示，二次确认由编辑器弹，
//  对齐 iOS ThoughtEditorView.editorOptionsMenu 同一口径）。
//

import SwiftUI

struct MacEditorFormatToolbar: View {

    /// 格式/插入动作（写入 pendingAction，由 MacRichTextEditor 消费）
    var onAction: (MarkdownEditorAction) -> Void
    /// 「插入图片」：打开 macOS 文件选择器（多选）
    var onPickImage: () -> Void
    /// 「完成」：保存并关闭编辑器
    var onDone: () -> Void
    /// 新建会话显示纸飞机 / 编辑会话显示 ✔（与 iOS 同口径）
    var isComposingSession: Bool
    /// 光标处格式状态（按钮高亮反馈）
    var formatState: TypingFormatState
    /// 「删除想法」可用（仅已落库想法；新建未落库会话不显示，与 iOS 同口径）
    var canDeleteThought: Bool
    /// 「删除想法」：编辑器弹二次确认后软删并关闭
    var onDeleteThought: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            toolButton("number", String(localized: "标签"), help: "插入 # 标签") {
                onAction(.insertTriggerCharacter("#"))
            }
            toolButton("at", String(localized: "引用想法"), help: "插入 @ 引用") {
                onAction(.insertTriggerCharacter("@"))
            }
            toolButton("photo", String(localized: "插入图片"), help: String(localized: "从文件选择图片")) {
                onPickImage()
            }

            separator

            toolButton(
                "bold",
                String(localized: "加粗"),
                help: String(localized: "加粗（⌘B）"),
                active: formatState.isBold
            ) {
                onAction(.toggleBold)
            }
            toolButton(
                "italic",
                String(localized: "斜体"),
                help: String(localized: "斜体（⌘I）"),
                active: formatState.isItalic
            ) {
                onAction(.toggleItalic)
            }
            toolButton(
                "underline",
                String(localized: "下划线"),
                help: String(localized: "下划线（⌘U）"),
                active: formatState.isUnderline
            ) {
                onAction(.toggleUnderline)
            }
            colorMenuButton

            separator

            toolButton("list.bullet", String(localized: "无序列表"), help: String(localized: "无序列表")) {
                onAction(.insertUnorderedList)
            }
            toolButton("list.number", String(localized: "有序列表"), help: String(localized: "有序列表")) {
                onAction(.insertOrderedList)
            }

            separator

            // 「…」更多操作（Phase E）：先承载「转为任务」（选区/整篇由编辑器统一分流）
            moreMenu

            Spacer(minLength: 12)

            doneButton
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Color.holoToolSurface)
        .overlay(alignment: .top) {
            Color.holoToolBorder.opacity(0.5).frame(height: 0.5)
        }
    }

    // MARK: - 文字颜色

    /// 预设色（与 iOS EditorFormatToolbar 同一组）
    private static let presetHexes: [String] = [
        "#000000", "#F46D38", "#60A5FA",
        "#22C55E", "#EF4444", "#C084FC",
        "#EC4899", "#10B981", "#8B5CF6"
    ]

    /// 颜色入口：下拉面板选色即关（Mac 用 Menu 承载，等效 iOS 色板浮层）
    private var colorMenuButton: some View {
        Menu {
            ForEach(Self.presetHexes, id: \.self) { hex in
                Button {
                    onAction(.setColor(hex: hex))
                } label: {
                    HStack {
                        Text(hex == "#000000" ? String(localized: "黑色") : String(localized: "颜色 \(hex)"))
                        if formatState.colorHex == hex {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(formatState.anyFormatActive ? .holoPrimary : .holoToolTextSecondary)
                .frame(width: 32, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(formatState.anyFormatActive ? Color.holoPrimary.opacity(0.1) : .clear))
                .overlay(alignment: .bottomTrailing) {
                    if let colorHex = formatState.colorHex {
                        Circle()
                            .fill(Color(hex: colorHex))
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color.holoToolSurface, lineWidth: 1))
                            .offset(x: -2, y: -2)
                    }
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "文字颜色"))
    }

    // MARK: - 更多操作菜单

    /// 「…」菜单：对齐 iOS 编辑器 editorOptionsMenu 的 Mac 对位。
    /// 「转为任务」经 .convertToTask 动作进入编辑器——有选中文字转选中部分，
    /// 无选中转整篇（分流在 MacRichTextEditor 内完成）。
    /// 「删除想法」仅已落库会话显示（iOS 同口径：currentThoughtId == nil 不显示）。
    private var moreMenu: some View {
        Menu {
            Button {
                onAction(.convertToTask)
            } label: {
                Label(String(localized: "转为任务"), systemImage: "checklist")
            }
            .accessibilityIdentifier("mac.thought.convertToTask")

            if canDeleteThought {
                Divider()
                Button(role: .destructive) {
                    onDeleteThought()
                } label: {
                    Label(String(localized: "删除想法"), systemImage: "trash")
                }
                .accessibilityIdentifier("mac.thought.deleteThoughtMenuItem")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color.holoToolTextSecondary)
                .frame(width: 32, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "更多操作"))
    }

    // MARK: - 完成键

    private var doneButton: some View {
        Button {
            onDone()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isComposingSession ? "paperplane.fill" : "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                Text(isComposingSession ? String(localized: "记录") : String(localized: "完成"))
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(Color.holoPrimary))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(isComposingSession ? String(localized: "记录") : String(localized: "完成"))
    }

    // MARK: - 基础元素

    private func toolButton(
        _ icon: String,
        _ label: String,
        help: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticManager.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(active ? .holoPrimary : .holoToolTextSecondary)
                .frame(width: 32, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(active ? Color.holoPrimary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    private var separator: some View {
        Color.holoToolBorder.opacity(0.5)
            .frame(width: 0.5, height: 18)
            .padding(.horizontal, 4)
    }
}
