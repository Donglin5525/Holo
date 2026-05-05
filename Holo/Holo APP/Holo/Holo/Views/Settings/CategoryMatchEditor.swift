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
            .background(Color.holoBackground)
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 原始分类信息

    private var originalInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("原始分类")
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary)

                Spacer()

                Text(matchResult.type.rawValue)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(matchResult.type == .expense ? Color.orange : Color.green)
                    .clipShape(Capsule())
            }

            HStack(spacing: 4) {
                Text(matchResult.originalPrimary)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                if matchResult.originalPrimary != matchResult.originalSub {
                    Text("/")
                        .foregroundColor(.holoTextSecondary)
                    Text(matchResult.originalSub)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.holoTextPrimary)
                }
            }

            if let matched = matchResult.matchedCategory {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundColor(.holoTextSecondary)
                    Text("当前匹配：")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                    Text(matched.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(matchResult.primaryCategoryMatched ? .green : .orange)
                    Text("(\(String(format: "%.0f%%", matchResult.confidence * 100)))")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(.holoTextSecondary)

            TextField("搜索分类", text: $searchText)
                .font(.system(size: 14))
        }
        .padding(HoloSpacing.sm)
        .background(Color.holoCardBackground)
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
                Image(category.icon)
                    .resizable()
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name)
                        .font(.system(size: 14))
                        .foregroundColor(.holoTextPrimary)

                    if let parent = parentName(of: category) {
                        Text(parent)
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary)
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
            .background(Color.holoCardBackground)
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
