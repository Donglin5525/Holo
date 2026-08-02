//
//  CategoryBudgetPicker.swift
//  Holo
//
//  分类预算设置 - 分类选择器（支持一级 + 二级分类选择）
//

import SwiftUI

struct CategoryBudgetPicker: View {

    @Binding var selectedCategory: Category?
    let categories: [Category]
    @Binding var expandedParentId: UUID?

    private var topLevelCategories: [Category] {
        categories
            .filter { $0.isTopLevel && !$0.isSystem }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("选择分类")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            // 可滚动分类列表
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(topLevelCategories, id: \.objectID) { parent in
                        parentCategoryRow(parent)

                        if expandedParentId == parent.id {
                            childCategoryGrid(parent)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)

            // 已选分类提示
            if let selected = selectedCategory {
                let scopeText = selected.isTopLevel
                    ? "覆盖全部子分类（\(childCount(of: selected)) 项）"
                    : "仅此项"
                HStack(spacing: HoloSpacing.sm) {
                    CategoryIconBadge(category: selected, diameter: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoPrimary)
                        Text(scopeText)
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                .padding(HoloSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.holoPrimary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Parent Category Row

    private func parentCategoryRow(_ parent: Category) -> some View {
        let isExpanded = expandedParentId == parent.id
        let isSelected = selectedCategory?.id == parent.id

        return HStack(spacing: 0) {
            // 点击主体区域 = 选中该一级分类（与二级分类单击选中行为一致）
            Button {
                selectedCategory = parent
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    // 图标
                    CategoryIconBadge(category: parent, diameter: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        // 名称
                        Text(parent.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoTextPrimary)

                        // 范围说明：含哪些子分类
                        if let scope = categoryScopeText(parent) {
                            Text(scope)
                                .font(.system(size: 11))
                                .foregroundColor(.holoTextSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(PlainButtonStyle())

            // 独立的展开箭头：控制子分类显隐，不影响选中
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedParentId = isExpanded ? nil : parent.id
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected
                      ? Color.holoPrimary.opacity(0.06)
                      : Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected
                        ? Color.holoPrimary.opacity(0.3)
                        : Color.clear, lineWidth: 1.5)
        )
    }

    // MARK: - Helpers

    /// 某一级分类下的子分类列表
    private func children(of parent: Category) -> [Category] {
        categories
            .filter { $0.parentId == parent.id }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 子分类数量
    private func childCount(of parent: Category) -> Int {
        children(of: parent).count
    }

    /// 一级分类的范围说明文案，如「含 餐饮·交通·购物 等 5 项」。
    /// 子分类 ≤3 个时全部列出；>3 个时列前 3 个并显示总数。
    private func categoryScopeText(_ parent: Category) -> String? {
        let children = children(of: parent)
        guard !children.isEmpty else { return nil }
        let names = children.prefix(3).map(\.name)
        if children.count <= 3 {
            return "含 \(names.joined(separator: "·"))"
        } else {
            return "含 \(names.joined(separator: "·")) 等 \(children.count) 项"
        }
    }

    // MARK: - Child Category Grid

    private func childCategoryGrid(_ parent: Category) -> some View {
        let children = children(of: parent)

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(children, id: \.objectID) { child in
                Button {
                    selectedCategory = child
                } label: {
                    VStack(spacing: 4) {
                        CategoryIconBadge(category: child, diameter: 40, isSelected: selectedCategory?.id == child.id)
                        Text(child.name)
                            .font(.system(size: 10))
                            .foregroundColor(selectedCategory?.id == child.id ? .holoPrimary : .holoTextSecondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
