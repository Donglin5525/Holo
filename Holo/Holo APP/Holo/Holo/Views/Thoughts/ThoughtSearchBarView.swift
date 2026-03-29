//
//  ThoughtSearchBarView.swift
//  Holo
//
//  观点模块 - 搜索栏组件
//  提供搜索输入和筛选功能
//

import SwiftUI

// MARK: - ThoughtSearchBarView

/// 搜索栏视图
struct ThoughtSearchBarView: View {

    // MARK: - Properties

    /// 搜索文本
    @Binding var searchText: String

    /// 占位符文本
    var placeholder: String = "搜索想法或标签..."

    /// 搜索回调
    var onSearch: ((String) -> Void)?

    /// 清除回调
    var onClear: (() -> Void)?

    /// 是否正在编辑
    @FocusState private var isEditing: Bool

    // MARK: - Body

    var body: some View {
        HStack(spacing: 8) {
            // 搜索图标
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(.holoTextSecondary)

            // 输入框
            TextField(placeholder, text: $searchText)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
                .focused($isEditing)
                .submitLabel(.search)
                .onSubmit {
                    onSearch?(searchText)
                }

            // 清除按钮
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    onClear?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(isEditing ? Color.holoPrimary : Color.holoBorder, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: isEditing)
    }
}

// MARK: - ThoughtSearchResultView

/// 搜索结果视图
struct ThoughtSearchResultView: View {

    // MARK: - Properties

    /// 搜索结果
    let results: [Thought]

    /// 点击结果回调
    var onSelect: ((Thought) -> Void)?

    // MARK: - Body

    var body: some View {
        if results.isEmpty {
            emptyResultView
        } else {
            resultListView
        }
    }

    // MARK: - Empty Result

    private var emptyResultView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("未找到相关想法")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            Text("尝试其他关键词或标签")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Result List

    private var resultListView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: HoloSpacing.sm) {
                ForEach(results) { thought in
                    SearchResultRow(thought: thought)
                        .onTapGesture {
                            onSelect?(thought)
                        }
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.sm)
        }
    }
}

// MARK: - Search Result Row

/// 搜索结果行
struct SearchResultRow: View {
    let thought: Thought

    var body: some View {
        HStack(spacing: HoloSpacing.sm) {
            // 心情图标
            if let moodType = thought.moodType {
                Text(moodType.emoji)
                    .font(.system(size: 24))
            } else {
                Image(systemName: "lightbulb")
                    .font(.system(size: 20))
                    .foregroundColor(.holoPrimary.opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 4) {
                // 预览文本
                Text(thought.previewText)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)

                // 日期和标签
                HStack(spacing: 8) {
                    Text(thought.formattedDate)
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)

                    if !thought.tagArray.isEmpty {
                        ForEach(thought.tagArray.prefix(2)) { tag in
                            Text("#\(tag.name)")
                                .font(.holoLabel)
                                .foregroundColor(tag.tagColor)
                        }

                        if thought.tagArray.count > 2 {
                            Text("+\(thought.tagArray.count - 2)")
                                .font(.holoLabel)
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
    }
}

// MARK: - Preview

#Preview("Search Bar") {
    VStack(spacing: 20) {
        ThoughtSearchBarView(searchText: .constant(""))
        ThoughtSearchBarView(searchText: .constant("工作"))
    }
    .padding()
    .background(Color.holoBackground)
}

#Preview("Search Result Row") {
    VStack {
        // SearchResultRow(thought: /* mock thought */)
        Text("需要 Core Data 环境预览")
    }
    .padding()
    .background(Color.holoBackground)
}