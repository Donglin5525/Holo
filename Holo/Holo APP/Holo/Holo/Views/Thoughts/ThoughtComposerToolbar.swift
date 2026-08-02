//
//  ThoughtComposerToolbar.swift
//  Holo
//
//  想法快速记录工具栏
//

import SwiftUI

/// 快速记录面板的底部工具栏。
/// 左侧工具区可横向滚动，语音与提交始终固定在右侧，兼容窄屏与动态字体。
struct ThoughtComposerToolbar: View {

    @Binding var pendingAction: MarkdownEditorAction?
    @Binding var smartSummaryEnabled: Bool

    let formatState: TypingFormatState
    let canSubmit: Bool
    let isSubmitting: Bool
    let onAddImage: () -> Void
    let onVoiceInput: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    toolButton(icon: "number", label: "标签") {
                        pendingAction = .insertTriggerCharacter("#")
                    }
                    toolButton(icon: "at", label: "引用想法") {
                        pendingAction = .insertTriggerCharacter("@")
                    }
                    toolButton(icon: "photo", label: "添加图片", action: onAddImage)
                    toolButton(
                        icon: "bold",
                        label: "加粗",
                        isActive: formatState.isBold
                    ) {
                        pendingAction = .toggleBold
                    }
                    toolButton(icon: "list.bullet", label: "无序列表") {
                        pendingAction = .insertUnorderedList
                    }
                    moreMenu
                }
            }
            .layoutPriority(0)

            Rectangle()
                .fill(Color.holoBorder.opacity(0.7))
                .frame(width: 1, height: 24)

            HStack(spacing: 6) {
                voiceButton
                submitButton
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.horizontal, HoloSpacing.sm)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoCardBackground)
    }

    private func toolButton(
        icon: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticManager.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 19, weight: isActive ? .bold : .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(ThoughtComposerToolButtonStyle(isActive: isActive))
        .accessibilityLabel(label)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                HapticManager.light()
                pendingAction = .insertOrderedList
            } label: {
                Label("有序列表", systemImage: "list.number")
            }

            Toggle(isOn: $smartSummaryEnabled) {
                Label("语音智能总结", systemImage: "sparkles")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多编辑工具")
    }

    private var voiceButton: some View {
        Button {
            HapticManager.selection()
            onVoiceInput()
        } label: {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(Color.holoCardBackground)
                    .overlay(
                        Circle()
                            .stroke(Color.holoPrimary.opacity(0.38), lineWidth: 1)
                    )

                Image(systemName: "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if smartSummaryEnabled {
                    Image(systemName: "sparkles")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.holoPrimary)
                        .padding(3)
                        .background(Color.holoCardBackground)
                        .clipShape(Circle())
                        .offset(x: 2, y: -2)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(ThoughtComposerCircleButtonStyle())
        .accessibilityLabel("语音输入")
        .accessibilityHint(smartSummaryEnabled ? "录音后智能总结并插入正文" : "录音并插入正文")
    }

    private var submitButton: some View {
        Button(action: onSubmit) {
            ZStack {
                Circle()
                    .fill(
                        canSubmit
                            ? Color.holoPrimary
                            : Color.holoTextSecondary.opacity(0.12)
                    )

                if isSubmitting {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(
                            canSubmit
                                ? .white
                                : .holoTextSecondary.opacity(0.42)
                        )
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(ThoughtComposerCircleButtonStyle())
        .disabled(!canSubmit || isSubmitting)
        .accessibilityLabel(isSubmitting ? "正在保存" : "保存想法")
    }
}

private struct ThoughtComposerToolButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isActive ? .holoPrimary : .holoTextPrimary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isActive
                            ? Color.holoPrimary.opacity(0.12)
                            : Color.holoTextPrimary.opacity(configuration.isPressed ? 0.06 : 0)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ThoughtComposerCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
