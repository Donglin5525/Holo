//
//  SuggestionPanelView.swift
//  Holo
//
//  观点模块 - 编辑器 #/@ 候选面板（光标吸附浮层版）
//  浮在编辑器内、紧贴光标上方，宽高自适应，去掉了原来吸底 240 的硬壳与 header
//

import SwiftUI

// MARK: - SuggestionPanelView

/// # 标签 / @ 引用候选浮层（紧凑卡片）
/// 由父视图（ThoughtEditorView）通过 .overlay 定位到光标 rect 上方，本视图只负责内容与样式
struct SuggestionPanelView: View {

    /// 候选行使用确定高度，避免滚动视口切在某一行中间。
    static let tagRowHeight: CGFloat = 44
    static let referenceRowHeight: CGFloat = 56
    static let emptyStateHeight: CGFloat = 44

    let context: EditorTriggerContext
    @ObservedObject var viewModel: SuggestionPanelViewModel
    /// 由父视图按光标上下可用空间计算，避免短编辑器或语音入口遮挡候选。
    var maxHeight: CGFloat = 224
    let onSelectTag: (UUID, String) -> Void
    let onCreateTag: (String) -> Void
    let onSelectReference: (UUID, String, String) -> Void

    /// 面板高度与候选行使用同一套规则：条目少时收紧，条目多时在完整行边界滚动。
    static func preferredHeight(
        for context: EditorTriggerContext,
        itemCount: Int,
        maxHeight: CGFloat
    ) -> CGFloat {
        guard itemCount > 0 else { return emptyStateHeight }

        let rowHeight: CGFloat
        switch context {
        case .tag:
            rowHeight = tagRowHeight
        case .reference:
            rowHeight = referenceRowHeight
        }
        return min(maxHeight, CGFloat(itemCount) * rowHeight)
    }

    private var isTagMode: Bool {
        if case .tag = context { return true }
        return false
    }

    private var panelHeight: CGFloat {
        Self.preferredHeight(
            for: context,
            itemCount: viewModel.visibleItems.count,
            maxHeight: maxHeight
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            candidateList
        }
        .frame(maxWidth: 280)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .stroke(Color.holoBorder.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 6)
    }

    // MARK: - 候选列表（紧凑，最多 4 行，更多条目可滚动）

    @ViewBuilder
    private var candidateList: some View {
        if viewModel.items.isEmpty {
            emptyState
                .padding(.vertical, 10)
                .padding(.horizontal, HoloSpacing.md)
        } else {
            // 高度按完整行计算；超过上限后才滚动，不在半行文字处硬裁剪。
            ScrollView(showsIndicators: viewModel.visibleItems.count > 4) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.visibleItems) { item in
                        row(for: item, isSelected: item.id == viewModel.selectedItem?.id)
                    }
                }
            }
            .frame(height: panelHeight)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: isTagMode ? "number" : "text.bubble")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.holoTextSecondary.opacity(0.7))
            Text(isTagMode ? "输入文字创建新标签" : "没有匹配的想法")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.8))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func row(for item: SuggestionPanelViewModel.Item, isSelected: Bool) -> some View {
        switch item {
        case .tag(let id, let path):
            tagRow(path: path, icon: "number", isSelected: isSelected, action: {
                viewModel.clearSelection()
                onSelectTag(id, path)
            })
        case .createTag(let path):
            tagRow(path: path, icon: "plus.circle.fill", isCreate: true, isSelected: isSelected, action: {
                viewModel.clearSelection()
                onCreateTag(path)
            })
        case .reference(let id, let title, let preview, let snapshot, let dateText):
            referenceRow(title: title, preview: preview, dateText: dateText, isSelected: isSelected) {
                viewModel.clearSelection()
                onSelectReference(id, title, snapshot)
            }
        }
    }

    private func tagRow(
        path: String,
        icon: String,
        isCreate: Bool = false,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isCreate ? .holoPrimary : .holoTextSecondary)
                    .frame(width: 18)
                Text("#\(path)")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(isCreate ? .holoPrimary : .holoTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.tagRowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? Color.holoPrimary.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func referenceRow(
        title: String,
        preview: String,
        dateText: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // 候选面板也保留 @ 前缀，和插入后的行内 Token、外层阅读态保持同一语义。
                    Text("@\(title)")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(dateText)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary.opacity(0.7))
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: Self.referenceRowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? Color.holoPrimary.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
