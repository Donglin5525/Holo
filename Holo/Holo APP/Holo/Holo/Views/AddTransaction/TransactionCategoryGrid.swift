//
//  TransactionCategoryGrid.swift
//  Holo
//
//  AddTransactionSheet 内联分类网格 — 5 列网格 + 下划线 Tab + 一级/二级下钻
//

import SwiftUI
import CoreData
import os

// MARK: - 分类网格视图

extension AddTransactionSheet {

    /// 支出/收入切换 Tab（下划线样式）
    var typeTabBar: some View {
        HStack(spacing: 0) {
            typeTabButton(title: "支出", isSelected: transactionType == .expense) {
                switchType(to: .expense)
            }
            typeTabButton(title: "收入", isSelected: transactionType == .income) {
                switchType(to: .income)
            }
        }
        .background(Color.holoCardBackground)
    }

    /// 分类网格区域（含标题行、一级/二级切换、管理入口）
    var categoryGrid: some View {
        VStack(spacing: 16) {
            // 标题行
            HStack {
                if let parent = drillDownParent {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            drillDownParent = nil
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text(parent.name)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(.holoPrimary)
                    }
                } else {
                    Text("选择分类")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                Button {
                    showCategoryManagement = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                        Text("管理")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.holoPrimary)
                }
            }

            // 最近常用分类（仅一级视图 + 有数据时显示）
            if drillDownParent == nil && !recentCategories.isEmpty {
                recentCategorySection
            }

            // 网格
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

            if drillDownParent != nil {
                // 二级子分类视图
                childCategoryGridView(columns: columns)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            } else {
                // 一级分类总览
                topLevelCategoryGridView(columns: columns)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .padding(16)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .animation(.easeInOut(duration: 0.25), value: drillDownParent?.objectID)
        .sheet(isPresented: $showCategoryManagement) {
            CategoryManagementView()
        }
        .sheet(isPresented: $showAddCategory) {
            AddCategorySheet(parentId: addCategoryParentId, type: transactionType) {
                Task { await loadCategories() }
            }
        }
        .onChange(of: showCategoryManagement) { _, isShowing in
            if !isShowing {
                Task { await loadCategories() }
            }
        }
    }

    /// 最近常用分类横向展示（胶囊样式，和下方完整分类网格区分层级）
    private var recentCategorySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("最近使用")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HoloSpacing.sm) {
                    ForEach(recentCategories, id: \.objectID) { category in
                        recentCategoryButton(category)
                    }
                }
            }
        }
    }

    /// 一级分类网格
    private func topLevelCategoryGridView(columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(topLevelCategories, id: \.objectID) { category in
                parentCategoryButton(category)
            }
            addTopLevelCategoryButton()
        }
    }

    /// 二级子分类网格
    private func childCategoryGridView(columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(childCategories, id: \.objectID) { category in
                childCategoryButton(category)
            }
            if let parent = drillDownParent {
                addChildCategoryButton(parent)
            }
        }
    }

    /// 类型 Tab 按钮（下划线样式）
    private func typeTabButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)

                Rectangle()
                    .fill(isSelected ? Color.holoPrimary : Color.clear)
                    .frame(width: 24, height: 3)
                    .clipShape(Capsule())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    /// 最近使用分类按钮
    private func recentCategoryButton(_ category: Category) -> some View {
        let isSelected = selectedCategory?.objectID == category.objectID
        return Button {
            withAnimation {
                selectedCategory = category
                drillDownParent = categories.first { $0.id == category.parentId }
            }
        } label: {
            HStack(spacing: 6) {
                transactionCategoryIcon(category, size: 16)

                Text(category.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .holoTextPrimary : .holoTextSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                Capsule()
                    .fill(category.swiftUIColor.opacity(isSelected ? 0.2 : 0.12))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? category.swiftUIColor : Color.holoTextSecondary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// 一级分类按钮 — 点击下钻到二级
    private func parentCategoryButton(_ category: Category) -> some View {
        let hasSelectedChild = selectedCategory.map { selected in
            childCategoriesForParent(category).contains { $0.objectID == selected.objectID }
                || selected.parentId == category.id
        } ?? false

        return Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                drillDownParent = category
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(hasSelectedChild
                              ? category.swiftUIColor.opacity(0.25)
                              : category.swiftUIColor.opacity(0.12))
                        .frame(width: 48, height: 48)

                    if hasSelectedChild {
                        Circle()
                            .stroke(category.swiftUIColor, lineWidth: 2.5)
                            .frame(width: 48, height: 48)
                    }

                    transactionCategoryIcon(category, size: 24)
                }
                Text(category.name)
                    .font(.system(size: 11))
                    .foregroundColor(hasSelectedChild ? .holoTextPrimary : .holoTextSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    /// 二级子分类按钮 — 点击选中
    private func childCategoryButton(_ category: Category) -> some View {
        let isSelected = selectedCategory?.objectID == category.objectID
        let parentColor = drillDownParent?.swiftUIColor ?? .holoPrimary

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedCategory = category
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(isSelected
                              ? parentColor.opacity(0.25)
                              : parentColor.opacity(0.12))
                        .frame(width: 48, height: 48)

                    if isSelected {
                        Circle()
                            .stroke(parentColor, lineWidth: 2.5)
                            .frame(width: 48, height: 48)
                    }

                    transactionCategoryIcon(category, size: 24)
                }
                Text(category.name)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .holoTextPrimary : .holoTextSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    /// 一级分类末尾的快速新增入口
    private func addTopLevelCategoryButton() -> some View {
        categoryAddButton(title: "新增", accessibilityLabel: "新增一级分类") {
            addCategoryParentId = nil
            showAddCategory = true
        }
    }

    /// 二级分类末尾的快速新增入口
    private func addChildCategoryButton(_ parent: Category) -> some View {
        categoryAddButton(title: "新增", accessibilityLabel: "在\(parent.name)下新增二级分类") {
            addCategoryParentId = parent.id
            showAddCategory = true
        }
    }

    private func categoryAddButton(
        title: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.holoPrimary.opacity(0.12))
                        .frame(width: 48, height: 48)

                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                }

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.holoPrimary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - 分类数据方法

extension AddTransactionSheet {

    /// 当前类型下的一级分类列表
    /// 不过滤「无子分类」的一级分类——用户新增的空一级分类也应当可见
    private var topLevelCategories: [Category] {
        categories
            .filter { top in
                top.transactionType == transactionType
                && top.isTopLevel
                && !top.isSystem
            }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 当前下钻父分类的二级子分类列表
    private var childCategories: [Category] {
        guard let parent = drillDownParent else { return [] }
        return childCategoriesForParent(parent)
    }

    /// 获取指定一级分类的二级子分类
    private func childCategoriesForParent(_ parent: Category) -> [Category] {
        categories
            .filter { $0.parentId == parent.id }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 切换收入/支出类型
    func switchType(to newType: TransactionType) {
        guard transactionType != newType else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            transactionType = newType
            drillDownParent = nil
            selectedCategory = nil
        }
        Task { await loadRecentCategories() }
    }

    /// 加载所有分类 + 最近常用
    /// 加载后同步清理已失效的 selectedCategory / drillDownParent 引用
    @MainActor
    func loadCategories() async {
        do {
            categories = try await FinanceRepository.shared.getAllCategories()
            await loadRecentCategories()
            cleanStaleCategoryRefs()
        } catch {
            Logger(subsystem: "com.holo.app", category: "CategoryGrid")
                .error("加载分类失败：\(error.localizedDescription)")
        }
    }

    /// 清理已删除分类的引用，避免 UI 访问已删除的 NSManagedObject 导致崩溃
    private func cleanStaleCategoryRefs() {
        let validIDs = Set(categories.map { $0.objectID })
        if let selected = selectedCategory, !validIDs.contains(selected.objectID) || selected.isDeleted {
            selectedCategory = nil
        }
        if let parent = drillDownParent, !validIDs.contains(parent.objectID) || parent.isDeleted {
            drillDownParent = nil
        }
    }

    /// 加载当前类型的最近常用分类
    @MainActor
    func loadRecentCategories() async {
        do {
            recentCategories = try await FinanceRepository.shared.getRecentCategories(
                type: transactionType
            )
        } catch {
            recentCategories = []
        }
    }
}
