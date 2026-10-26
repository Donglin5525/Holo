//
//  CategoryMatchEditor.swift
//  Holo
//
//  分类映射编辑弹窗 — 用户手动选择分类或确认新建
//

import SwiftUI

struct CategoryMatchEditor: View {

    @Environment(\.dismiss) var dismiss
    @State private var searchText: String = ""

    let matchResult: CategoryMatchResult
    let allCategories: [Category]
    let onSelectCategory: (Category) -> Void
    let onConfirmCreateNew: () -> Void
    let onDismiss: () -> Void

    /// 搜索过滤后的分类
    private var filteredCategories: [Category] {
        let subs = allCategories.filter { $0.isSubCategory }
        if searchText.isEmpty { return subs }
        return subs.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || parentName(of: $0).map { $0.localizedCaseInsensitiveContains(searchText) } ?? false
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 原始分类信息
                originalInfoSection

                Divider()

                // 搜索框
                searchBar

                // 分类列表
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        if filteredCategories.isEmpty {
                            HoloInlineState(kind: .empty, message: String(localized: "没有匹配的分类，请换个关键词。"))
                                .padding(HoloSpacing.md)
                        }
                        ForEach(filteredCategories, id: \.id) { category in
                            categoryRow(category)
                        }
                    }
                }

                // 底部操作
                if matchResult.matchType == .unmatched {
                    Divider()
                    confirmCreateNewButton
                }
            }
            .background(Color.holoToolBackground)
            #if canImport(UIKit)
        .navigationBarHidden(true)
            #endif
        }
        .holoSheetShell()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 原始分类信息

    private var originalInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("原始分类")
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)

                Spacer()

                Text(matchResult.type.rawValue)
                    .holoText(.metadata)
                    .foregroundColor(matchResult.type == .expense ? .holoToolError : .holoToolSuccess)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((matchResult.type == .expense ? Color.holoToolError : Color.holoToolSuccess).opacity(0.1))
                    .clipShape(Capsule())
            }

            HStack(spacing: 4) {
                Text(matchResult.originalPrimary)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.holoToolText)
                if matchResult.originalPrimary != matchResult.originalSub {
                    Text("/")
                        .foregroundColor(.holoToolTextSecondary)
                    Text(matchResult.originalSub)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.holoToolText)
                }
            }

            if let matched = matchResult.matchedCategory {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .holoText(.metadata)
                        .foregroundColor(.holoToolTextSecondary)
                    Text("当前匹配：")
                        .holoText(.metadata)
                        .foregroundColor(.holoToolTextSecondary)
                    Text(matched.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(matchResult.primaryCategoryMatched ? .holoToolSuccess : .holoToolWarning)
                    Text("(\(String(format: "%.0f%%", matchResult.confidence * 100)))")
                        .holoText(.metadata)
                        .foregroundColor(.holoToolTextSecondary)
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoToolSurface)
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary)

            TextField("搜索分类", text: $searchText)
                .holoText(.supporting)
        }
        .padding(HoloSpacing.sm)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
    }

    // MARK: - 分类行

    private func categoryRow(_ category: Category) -> some View {
        Button {
            onSelectCategory(category)
        } label: {
            HStack(spacing: 8) {
                categoryIconGlyph(category.icon, size: 20, color: category.swiftUIColor)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name)
                        .holoText(.supporting)
                        .foregroundColor(.holoToolText)

                    if let parent = parentName(of: category) {
                        Text(parent)
                            .holoText(.metadata)
                            .foregroundColor(.holoToolTextSecondary)
                    }
                }

                Spacer()

                // 当前匹配标记
                if let matched = matchResult.matchedCategory, matched.id == category.id {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.holoPrimary)
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 10)
            .background(Color.holoToolSurface)
        }
    }

    // MARK: - 确认新建按钮

    private var confirmCreateNewButton: some View {
        Button {
            onConfirmCreateNew()
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                Text("确认创建新分类「\(matchResult.originalSub)」")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.holoPrimary)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
        }
    }

    // MARK: - 辅助方法

    private func parentName(of category: Category) -> String? {
        guard let parentId = category.parentId else { return nil }
        return allCategories.first(where: { $0.id == parentId })?.name
    }
}
