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

    let context: EditorTriggerContext
    @ObservedObject var viewModel: SuggestionPanelViewModel
    let onSelectTag: (UUID, String) -> Void
    let onCreateTag: (String) -> Void
    let onSelectReference: (UUID, String, String) -> Void

    private var isTagMode: Bool {
        if case .tag = context { return true }
        return false
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

    // MARK: - 候选列表（紧凑，最多 5 行 + 创建项）

    @ViewBuilder
    private var candidateList: some View {
        if viewModel.items.isEmpty {
            emptyState
                .padding(.vertical, 10)
                .padding(.horizontal, HoloSpacing.md)
        } else {
            // 滚动容器限高，避免候选过多撑爆编辑器
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.items.prefix(6)) { item in
                        row(for: item)
                    }
                }
            }
            .frame(maxHeight: 232)
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
    private func row(for item: SuggestionPanelViewModel.Item) -> some View {
        switch item {
        case .tag(let id, let path):
            tagRow(path: path, icon: "number", action: {
                onSelectTag(id, path)
            })
        case .createTag(let path):
            tagRow(path: path, icon: "plus.circle.fill", isCreate: true, action: {
                onCreateTag(path)
            })
        case .reference(let id, let title, let preview, let snapshot, let dateText):
            referenceRow(title: title, preview: preview, dateText: dateText) {
                onSelectReference(id, title, snapshot)
            }
        }
    }

    private func tagRow(
        path: String,
        icon: String,
        isCreate: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isCreate ? .holoPrimary : .holoTextSecondary)
                    .frame(width: 18)
                Text("#\(path)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isCreate ? .holoPrimary : .holoTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func referenceRow(title: String, preview: String, dateText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
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
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
