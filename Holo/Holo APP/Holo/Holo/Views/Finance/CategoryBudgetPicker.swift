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
                HStack(spacing: HoloSpacing.sm) {
                    ZStack {
                        Circle()
                            .fill(selected.swiftUIColor.opacity(0.15))
                            .frame(width: 28, height: 28)
                        Image(systemName: selected.icon)
                            .font(.system(size: 13))
                            .foregroundColor(selected.swiftUIColor)
                    }
                    Text("已选：\(selected.name)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoPrimary)
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
        Button {
            if expandedParentId == parent.id {
                expandedParentId = nil
            } else {
                expandedParentId = parent.id
            }
        } label: {
            HStack(spacing: HoloSpacing.md) {
                // 图标
                ZStack {
                    Circle()
                        .fill(parent.swiftUIColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: parent.icon)
                        .font(.system(size: 16))
                        .foregroundColor(parent.swiftUIColor)
                }

                // 名称
                Text(parent.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                // 展开箭头
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .rotationEffect(.degrees(expandedParentId == parent.id ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selectedCategory?.id == parent.id
                          ? Color.holoPrimary.opacity(0.06)
                          : Color.holoCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selectedCategory?.id == parent.id
                            ? Color.holoPrimary.opacity(0.3)
                            : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(PlainButtonStyle())
        // 选择父分类（长按或单独点击区域）
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                selectedCategory = parent
            }
        )
        .contextMenu {
            Button {
                selectedCategory = parent
            } label: {
                Label("选择「\(parent.name)」作为预算分类", systemImage: "checkmark")
            }
        }
    }

    // MARK: - Child Category Grid

    private func childCategoryGrid(_ parent: Category) -> some View {
        let children = categories
            .filter { $0.parentId == parent.id }
            .sorted { $0.sortOrder < $1.sortOrder }

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(children, id: \.objectID) { child in
                Button {
                    selectedCategory = child
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(child.swiftUIColor.opacity(selectedCategory?.id == child.id ? 0.15 : 0.1))
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Circle()
                                        .stroke(selectedCategory?.id == child.id ? Color.holoPrimary : Color.clear, lineWidth: 2)
                                )
                            Image(systemName: child.icon)
                                .font(.system(size: 15))
                                .foregroundColor(child.swiftUIColor)
                        }
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
