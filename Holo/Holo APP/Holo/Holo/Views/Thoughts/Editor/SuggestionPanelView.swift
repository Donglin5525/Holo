//
//  SuggestionPanelView.swift
//  Holo
//
//  观点模块 - 编辑器 #/@ 候选面板
//  展示在键盘上方，选择后替换触发区间为 Token
//

import SwiftUI

// MARK: - SuggestionPanelView

/// # 标签 / @ 引用候选面板
struct SuggestionPanelView: View {

    let context: EditorTriggerContext
    @ObservedObject var viewModel: SuggestionPanelViewModel
    let onSelectTag: (UUID, String) -> Void
    let onCreateTag: (String) -> Void
    let onSelectReference: (UUID, String, String) -> Void
    let onClose: () -> Void

    private var isTagMode: Bool {
        if case .tag = context { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.holoBorder)
            candidateList
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .background(Color.holoCardBackground)
        .overlay(
            Rectangle()
                .fill(Color.holoBorder)
                .frame(height: 1),
            alignment: .top
        )
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Text(isTagMode ? "选择标签" : "引用想法")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("关闭候选面板")
        }
        .padding(.horizontal, HoloSpacing.md)
        .frame(height: 36)
    }

    // MARK: - 候选列表

    private var candidateList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if viewModel.items.isEmpty {
                    emptyState
                } else {
                    ForEach(viewModel.items) { item in
                        row(for: item)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        Text(isTagMode ? "输入关键词搜索或创建标签" : "没有匹配的想法")
            .font(.holoCaption)
            .foregroundColor(.holoTextSecondary.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, HoloSpacing.lg)
    }

    @ViewBuilder
    private func row(for item: SuggestionPanelViewModel.Item) -> some View {
        switch item {
        case .tag(let id, let path):
            tagRow(path: path, icon: "number") {
                onSelectTag(id, path)
            }
        case .createTag(let path):
            tagRow(path: path, icon: "plus") {
                onCreateTag(path)
            }
        case .reference(let id, let title, let preview, let snapshot, let dateText):
            referenceRow(title: title, preview: preview, dateText: dateText) {
                onSelectReference(id, title, snapshot)
            }
        }
    }

    private func tagRow(path: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 20)
                Text("#\(path)")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, HoloSpacing.md)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func referenceRow(title: String, preview: String, dateText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(dateText)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
