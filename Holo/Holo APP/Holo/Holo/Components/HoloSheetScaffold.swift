//
//  HoloSheetScaffold.swift
//  Holo
//
//  通用弹层脚手架（2026-10-17 口径收敛，规范 §8.8）：
//  标题 + 左上 X 圆钮关闭 + 右上主操作文字 + 恒显示拖拽指示条 +
//  底部唯一主操作按钮（safeAreaInset 贴底，任何数据状态/任何 detent 都不悬空）。
//  样式全走 token：关闭钮对照 SettingsView 的 xmark 语言（14pt 次要色），
//  主按钮为实心 holoToolAction 胶囊（§8.8 规则 2），底部衬底沿用 TaskCreationSheet
//  的 ultraThinMaterial 贴底条同构。
//

import SwiftUI

/// 弹层统一外壳。内容区（列表/表单/滚动视图）由调用方以 ViewBuilder 传入，
/// 脚手架不拥有滚动，`presentationDetents` 等展示参数也由调用方按需追加。
struct HoloSheetScaffold<Content: View>: View {

    /// 弹层标题（单行，超长尾部截断）
    let title: String
    /// 左上 X 圆钮关闭回调；nil 时不渲染关闭钮
    var onClose: (() -> Void)? = nil
    /// 右上主操作文字（全屏编辑页的「保存」类动作）；nil 时不渲染
    var trailingTitle: String? = nil
    /// 右上主操作回调，与 trailingTitle 成对出现
    var trailingAction: (() -> Void)? = nil
    /// 底部主按钮文字；nil 时无底部操作区
    var primaryTitle: String? = nil
    /// 底部主按钮回调，与 primaryTitle 成对出现
    var primaryAction: (() -> Void)? = nil
    /// 底部主按钮禁用态（禁用时 holoToolInset 中性实底，与 §8.1 一致）
    var primaryDisabled: Bool = false
    /// 内容区
    let content: () -> Content

    init(
        title: String,
        onClose: (() -> Void)? = nil,
        trailingTitle: String? = nil,
        trailingAction: (() -> Void)? = nil,
        primaryTitle: String? = nil,
        primaryAction: (() -> Void)? = nil,
        primaryDisabled: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.onClose = onClose
        self.trailingTitle = trailingTitle
        self.trailingAction = trailingAction
        self.primaryTitle = primaryTitle
        self.primaryAction = primaryAction
        self.primaryDisabled = primaryDisabled
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .holoSheetShell()
        .background(Color.holoToolBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { primaryFooter }
        .presentationDragIndicator(.visible)
    }

    // MARK: 头部（关闭 X 圆钮 / 标题 / 右上主操作）

    private var sheetHeader: some View {
        HStack(spacing: HoloSpacing.sm) {
            if let onClose {
                closeButton(action: onClose)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }

            Spacer(minLength: 0)

            Text(title)
                .holoText(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Color.holoToolText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if let trailingTitle, let trailingAction {
                trailingButton(title: trailingTitle, action: trailingAction)
            } else if onClose != nil {
                // 单侧关闭时补等宽占位，标题保持视觉居中
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, HoloSpacing.sm)
        .padding(.vertical, HoloSpacing.xs)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.holoToolBorder.opacity(0.5))
                .frame(height: 0.5)
        }
    }

    /// 左上关闭：14pt xmark 次要色（对照 SettingsView），32pt 可见圆底 + 44pt 热区
    private func closeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.holoToolSurface))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
        .accessibilityLabel(Text(String(localized: "关闭")))
    }

    /// 右上主操作：行动色文字按钮，44pt 热区
    private func trailingButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .holoText(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Color.holoToolAction)
                .lineLimit(1)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
    }

    // MARK: 底部主操作（唯一，贴底）

    @ViewBuilder
    private var primaryFooter: some View {
        if let primaryTitle, let primaryAction {
            Button(action: primaryAction) {
                Text(primaryTitle)
                    .holoText(.body)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(primaryDisabled ? Color.holoToolTextSecondary : Color.holoToolOnAction)
                    .background(
                        Capsule().fill(primaryDisabled ? Color.holoToolInset : Color.holoToolAction)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoloPressStyle())
            .disabled(primaryDisabled)
            .padding(.horizontal, HoloSpacing.page)
            .padding(.top, HoloSpacing.sm)
            .padding(.bottom, HoloSpacing.sm)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
        }
    }
}
