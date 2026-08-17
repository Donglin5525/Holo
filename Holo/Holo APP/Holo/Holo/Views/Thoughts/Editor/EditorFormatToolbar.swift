//
//  EditorFormatToolbar.swift
//  Holo
//
//  观点模块 - 编辑器格式工具栏（编辑器卡片的一部分）
//
//  设计原则：工具栏不是「贴在键盘上的另一块面板」，而是输入框自身的底部——
//  沉在编辑器卡片内、与卡片同底色（holoCardBackground）、圆角随卡片一体，
//  仅以一条发丝线（holoDivider 0.5pt）与正文区分层。
//  布局：左侧 6 个格式/插入工具（次要文字色），右侧 2 个核心动作（品牌色）——
//  「转为任务」图标强调，「语音输入」品牌色实心圆是整条工具栏的视觉锚点。
//

import SwiftUI

// MARK: - EditorFormatToolbar

/// 编辑器卡片内嵌的格式工具栏。
/// 动作统一走 `MarkdownEditorAction` 管线（SwiftUI 侧不直接触碰 UITextView）。
struct EditorFormatToolbar: View {

    /// 格式/插入动作（写入 pendingAction，由 MarkdownTextView 消费）
    var onAction: (MarkdownEditorAction) -> Void
    /// 「转为任务」：编辑器读当前选区（有选中转选中，无选中转整篇）
    var onConvertToTask: () -> Void
    /// 「添加图片」：弹来源选择
    var onAddImage: () -> Void
    /// 「语音输入」：弹语音面板
    var onVoiceInput: () -> Void
    /// 智能总结开关（长按语音按钮切换；绑定 AppStorage）
    @Binding var smartSummaryEnabled: Bool
    /// 光标处格式状态（B/样式入口高亮、颜色指示点）
    var formatState: TypingFormatState
    /// 色板显隐（由宿主管理：光标活动/触发候选时关闭）
    @Binding var showsColorPalette: Bool

    var body: some View {
        HStack(spacing: 0) {
            formatTools

            Spacer(minLength: 8)

            actionTools
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            // 发丝线与正文区分层——卡片内分层的唯一手段，不再自绘面板背景
            Color.holoDivider.opacity(0.5)
                .frame(height: 0.5)
                .padding(.horizontal, 12)
        }
        .overlay(alignment: .bottom) {
            colorPalette
        }
        .zIndex(1)
    }

    // MARK: - 格式工具组

    /// 左组：内容插入（# @ 📷）+ 文字样式（B 样式菜单）+ 列表菜单
    private var formatTools: some View {
        HStack(spacing: 0) {
            toolButton("number", "标签") {
                onAction(.insertTriggerCharacter("#"))
            }
            toolButton("at", "引用想法") {
                onAction(.insertTriggerCharacter("@"))
            }
            toolButton("photo", "添加图片") {
                onAddImage()
            }

            groupDivider

            toolButton("bold", "加粗", active: formatState.isBold) {
                onAction(.toggleBold)
            }

            styleMenuButton

            listMenuButton
        }
    }

    /// 文字样式入口（菜单：斜体/下划线/文字颜色）
    /// 任一格式激活时入口高亮；颜色生效时右下角显示当前色圆点
    private var styleMenuButton: some View {
        Menu {
            Button {
                onAction(.toggleItalic)
            } label: {
                Label("斜体", systemImage: "italic")
            }
            Button {
                onAction(.toggleUnderline)
            } label: {
                Label("下划线", systemImage: "underline")
            }
            Button {
                showsColorPalette = true
            } label: {
                Label("文字颜色", systemImage: "paintpalette")
            }
        } label: {
            // 不使用 textformat：中文系统下该符号的视觉形态容易被看成「格式」文字
            Image(systemName: "paintbrush.pointed")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(formatState.anyFormatActive ? .holoPrimary : .holoTextSecondary)
                .frame(width: 40, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(formatState.anyFormatActive ? Color.holoPrimary.opacity(0.1) : .clear)
                )
                .overlay(alignment: .bottomTrailing) {
                    if let colorHex = formatState.colorHex {
                        // 当前颜色指示点：白描边把它从正文底色里「挖」出来
                        Circle()
                            .fill(Color(hex: colorHex))
                            .frame(width: 8, height: 8)
                            .overlay(
                                Circle().stroke(Color.holoCardBackground, lineWidth: 1.5)
                            )
                            .offset(x: -2, y: -2)
                    }
                }
        }
        .accessibilityLabel("文字样式")
    }

    /// 列表入口（菜单：无序/有序）
    private var listMenuButton: some View {
        Menu {
            Button {
                onAction(.insertUnorderedList)
            } label: {
                Label("无序列表", systemImage: "list.bullet")
            }
            Button {
                onAction(.insertOrderedList)
            } label: {
                Label("有序列表", systemImage: "list.number")
            }
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 40, height: 44)
        }
        .accessibilityLabel("列表")
    }

    // MARK: - 动作组

    /// 右组：转为任务（品牌色图标）+ 语音输入（品牌色实心圆，视觉锚点）。
    /// 按钮宽 38/36（比左组略紧），保证最小屏（375pt）上整条工具栏不溢出。
    private var actionTools: some View {
        HStack(spacing: 0) {
            toolButton("checklist", "转为任务", tint: .holoPrimary, width: 38) {
                onConvertToTask()
            }
            .accessibilityHint("将选中的文字转为任务；未选中文字时提取整篇想法")

            voiceButton
        }
    }

    /// 语音输入：整条工具栏唯一的实心品牌圆，位置固定在最右（拇指热区）。
    /// 智能总结开关收进长按菜单——低频偏好设置不占工具栏宽度。
    private var voiceButton: some View {
        Button {
            onVoiceInput()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.holoPrimary))
                .frame(width: 36, height: 44)
        }
        .contextMenu {
            Button {
                smartSummaryEnabled.toggle()
            } label: {
                Label(
                    smartSummaryEnabled ? "关闭智能总结" : "开启智能总结",
                    systemImage: smartSummaryEnabled ? "sparkles" : "sparkle"
                )
            }
        }
        .accessibilityLabel("语音输入")
        .accessibilityHint("长按可切换智能总结")
    }

    // MARK: - 色板

    /// 文字颜色浮层：工具栏上方的一条「颜色尺」，居中展示、选色即关。
    /// 黑色是普通颜色选项，不提供「重置颜色」特殊状态。
    @ViewBuilder
    private var colorPalette: some View {
        if showsColorPalette {
            HStack(spacing: 8) {
                ForEach(Self.presetHexes, id: \.self) { hex in
                    let isSelected = formatState.colorHex == hex
                    Button {
                        HapticManager.light()
                        onAction(.setColor(hex: hex))
                        withAnimation(HoloAnimation.standard) {
                            showsColorPalette = false
                        }
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle()
                                    .stroke(
                                        isSelected ? Color.holoPrimary : Color.holoBorder.opacity(0.5),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                            )
                    }
                    .accessibilityLabel(hex == "#000000" ? "黑色" : "颜色 \(hex)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(Color.holoCardBackground)
                    .shadow(color: Color.black.opacity(0.1), radius: 14, x: 0, y: 5)
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .stroke(Color.holoBorder.opacity(0.6), lineWidth: 0.5)
                    )
            )
            .offset(y: -54)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)).animation(HoloAnimation.standard),
                    removal: .opacity.animation(HoloAnimation.quick)
                )
            )
        }
    }

    /// 预设色（与设计系统一致）
    private static let presetHexes: [String] = [
        "#000000", "#F46D38", "#60A5FA",
        "#22C55E", "#EF4444", "#C084FC",
        "#EC4899", "#10B981", "#8B5CF6"
    ]

    // MARK: - 基础元素

    /// 普通工具按钮：默认 40×44 点击区，17pt 图标（与正文字号同量级），普通态次要文字色
    private func toolButton(
        _ icon: String,
        _ label: String,
        tint: Color = .holoTextSecondary,
        active: Bool = false,
        width: CGFloat = 40,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticManager.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(active ? .holoPrimary : tint)
                .frame(width: width, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(active ? Color.holoPrimary.opacity(0.1) : .clear)
                )
        }
        .accessibilityLabel(label)
    }

    /// 组间分隔：0.5pt 发丝线，与顶部分隔同一语言
    private var groupDivider: some View {
        Color.holoBorder.opacity(0.5)
            .frame(width: 0.5, height: 18)
            .padding(.horizontal, 4)
    }
}
