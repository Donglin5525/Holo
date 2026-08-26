//
//  EmojiIconPicker.swift
//  Holo
//
//  全 App 通用 emoji 图标选择器（知识树 v1 的 TopicIconPickerSheet 提取通用化）。
//  - EmojiCatalogGrid：单页连续滚动的网格内容（顶部最近使用 + 分组小节标题），可嵌入表单或弹层
//  - EmojiIconPickerSheet：sheet 弹层壳，供目标/纪念日/主题等「点按换图标」场景
//

import SwiftUI

// MARK: - Emoji 网格内容

/// emoji 网格：顶部搜索框 + 单页连续滚动（无分类切换），分组仅作滚动中的小节标题；
/// 搜索时整库按中英文关键词实时过滤；非搜索态顶部展示最近使用
struct EmojiCatalogGrid: View {

    /// 当前已选图标（传实际展示值，含默认回退；用于高亮标记）
    var currentIcon: String? = nil

    /// 选中回调；是否关闭容器由调用方决定
    let onSelect: (String) -> Void

    @State private var recentEmojis: [String] = []
    @State private var searchText = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()

            ScrollView(showsIndicators: false) {
                if trimmedQuery.isEmpty {
                    LazyVStack(alignment: .leading, spacing: HoloSpacing.md, pinnedViews: []) {
                        if !recentEmojis.isEmpty {
                            emojiSection(title: "最近使用", emojis: recentEmojis)
                        }
                        ForEach(EmojiCatalog.categories) { category in
                            emojiSection(title: category.title, emojis: category.emojis)
                        }
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, HoloSpacing.md)
                } else {
                    searchResultList
                }
            }
        }
        .background(Color.holoBackground)
        .onAppear {
            recentEmojis = EmojiCatalog.loadRecent()
        }
    }

    // MARK: - 搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoTextSecondary)

            TextField("搜索 emoji，如：跑步、咖啡、coffee", text: $searchText)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.holoTextSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 8)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
    }

    @ViewBuilder
    private var searchResultList: some View {
        let results = EmojiCatalog.search(matching: trimmedQuery)
        if results.isEmpty {
            VStack(spacing: HoloSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.holoTextSecondary.opacity(0.3))
                Text("没有找到「\(trimmedQuery)」相关的 emoji")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        } else {
            LazyVStack(alignment: .leading, spacing: HoloSpacing.md, pinnedViews: []) {
                emojiSection(title: "搜索结果 · \(results.count) 个", emojis: results)
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.md)
        }
    }

    private func emojiSection(title: String, emojis: [String]) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(title)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(emojis, id: \.self) { emoji in
                    emojiCell(emoji)
                }
            }
        }
    }

    private func emojiCell(_ emoji: String) -> some View {
        let isCurrent = currentIcon == emoji
        return Button {
            EmojiCatalog.pushRecent(emoji)
            onSelect(emoji)
        } label: {
            Text(emoji)
                .font(.system(size: 26))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(isCurrent ? Color.holoPrimary.opacity(0.14) : Color.holoCardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .stroke(isCurrent ? Color.holoPrimary : Color.holoBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Emoji 选择器弹层

/// emoji 图标选择 sheet：选完即关闭
struct EmojiIconPickerSheet: View {

    /// 当前已选图标（传实际展示值，含默认回退；用于高亮标记）
    var currentIcon: String? = nil

    /// 选中回调（sheet 会自行关闭）
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EmojiCatalogGrid(currentIcon: currentIcon) { emoji in
                onSelect(emoji)
                dismiss()
            }
            .navigationTitle("选择图标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

#Preview {
    EmojiIconPickerSheet(currentIcon: "🎯") { _ in }
}
