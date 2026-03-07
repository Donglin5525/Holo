//
//  CategoryPicker.swift
//  Holo
//
//  分类选择器组件
//  支持收入/支出 Tab 切换、一级分类展示、下钻二级子分类选择
//

import SwiftUI
import CoreData
import UIKit

/// 分类选择器视图
/// 交互流程：Tab 切换类型 → 一级分类网格 → 点击下钻展示二级子分类 → 选中二级分类
struct CategoryPicker: View {
    
    // MARK: - Properties
    
    /// 当前选中的分类（二级子分类）
    @Binding var selectedCategory: Category?
    
    /// 交易类型（收入/支出），改为 Binding 以支持 Tab 切换时联动外部状态
    @Binding var transactionType: TransactionType
    
    /// 所有分类数据（含一级和二级）
    @State private var categories: [Category] = []
    
    /// 最近常用的二级子分类（按使用频率排序）
    @State private var recentCategories: [Category] = []
    
    /// 当前下钻查看的一级分类（nil 表示处于一级分类总览视图）
    @State private var drillDownParent: Category?
    
    /// 是否显示分类管理页面
    @State private var showCategoryManagement = false
    
    /// 4 列网格布局
    private let gridColumns = Array(
        repeating: GridItem(.flexible()),
        count: 4
    )
    
    // MARK: - Computed Properties
    
    /// 当前类型下的一级分类列表（仅展示“有子分类”的一级，排除旧版扁平分类）
    private var topLevelCategories: [Category] {
        categories
            .filter { top in
                top.transactionType == transactionType
                && top.isTopLevel
                && categories.contains { $0.parentId == top.id }
            }
            .sorted { $0.sortOrder < $1.sortOrder }
    }
    
    /// 当前下钻父分类的二级子分类列表
    private var childCategories: [Category] {
        guard let parent = drillDownParent else { return [] }
        return categories
            .filter { $0.parentId == parent.id }
            .sorted { $0.sortOrder < $1.sortOrder }
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // --- 管理分类入口 ---
            Button {
                showCategoryManagement = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                    Text("管理分类")
                        .font(.holoCaption)
                }
                .foregroundColor(.holoPrimary)
            }
            
            // --- 收入/支出 Tab 栏 ---
            typeTabBar
            
            // --- 最近常用分类（仅在一级视图且有历史数据时显示）---
            if drillDownParent == nil && !recentCategories.isEmpty {
                recentSection
            }
            
            // --- 分类网格区域 ---
            if drillDownParent != nil {
                drillDownView
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            } else {
                topLevelGridView
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .padding(HoloSpacing.md)
        .animation(.easeInOut(duration: 0.25), value: drillDownParent?.objectID)
        .sheet(isPresented: $showCategoryManagement) {
            CategoryManagementView()
        }
        .onChange(of: showCategoryManagement) { _, isShowing in
            if !isShowing {
                Task { await loadCategories() }
            }
        }
        .task {
            await loadCategories()
        }
    }
    
    // MARK: - Sub Views
    
    /// 收入/支出切换 Tab 栏
    private var typeTabBar: some View {
        HStack(spacing: HoloSpacing.xs) {
            TypeTabButton(
                title: "支出",
                isSelected: transactionType == .expense
            ) {
                switchType(to: .expense)
            }
            
            TypeTabButton(
                title: "收入",
                isSelected: transactionType == .income
            ) {
                switchType(to: .income)
            }
            
            Spacer()
        }
    }
    
    /// 最近常用分类横向展示区
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("最近使用")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HoloSpacing.md) {
                    ForEach(recentCategories, id: \.objectID) { category in
                        PickerCategoryButton(
                            category: category,
                            isSelected: selectedCategory?.objectID == category.objectID
                        ) {
                            selectedCategory = category
                        }
                        .frame(width: 64)
                    }
                }
            }
        }
    }
    
    /// 一级分类网格视图
    private var topLevelGridView: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("选择分类")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            
            LazyVGrid(columns: gridColumns, spacing: HoloSpacing.md) {
                ForEach(topLevelCategories, id: \.objectID) { category in
                    PickerCategoryButton(
                        category: category,
                        isSelected: false
                    ) {
                        withAnimation {
                            drillDownParent = category
                        }
                    }
                }
            }
        }
    }
    
    /// 二级分类下钻视图（含返回按钮）
    private var drillDownView: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 返回按钮 + 当前一级分类名称
            Button {
                withAnimation {
                    drillDownParent = nil
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text(drillDownParent?.name ?? "")
                        .font(.holoCaption)
                }
                .foregroundColor(.holoPrimary)
            }
            
            LazyVGrid(columns: gridColumns, spacing: HoloSpacing.md) {
                ForEach(childCategories, id: \.objectID) { category in
                    PickerCategoryButton(
                        category: category,
                        isSelected: selectedCategory?.objectID == category.objectID
                    ) {
                        selectedCategory = category
                    }
                }
            }
        }
    }
    
    // MARK: - Methods
    
    /// 切换收入/支出类型，同时重置下钻和选中状态
    private func switchType(to newType: TransactionType) {
        guard transactionType != newType else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            transactionType = newType
            drillDownParent = nil
            selectedCategory = nil
        }
        // 切换类型后异步刷新最近常用
        Task { await loadRecentCategories() }
    }
    
    /// 从 Core Data 加载所有分类 + 最近常用
    @MainActor
    private func loadCategories() async {
        do {
            categories = try await FinanceRepository.shared.getAllCategories()
            await loadRecentCategories()
        } catch {
            print("加载分类失败：\(error.localizedDescription)")
        }
    }
    
    /// 加载当前类型的最近常用分类（最近 30 天、最多 8 个）
    @MainActor
    private func loadRecentCategories() async {
        do {
            recentCategories = try await FinanceRepository.shared.getRecentCategories(
                type: transactionType
            )
        } catch {
            recentCategories = []
        }
    }
}

// MARK: - 类型切换 Tab 按钮

/// 收入/支出类型切换按钮
private struct TypeTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.holoCaption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .white : .holoTextSecondary)
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.sm)
                .background(
                    isSelected
                        ? AnyShapeStyle(Color.holoPrimary)
                        : AnyShapeStyle(Color.holoTextSecondary.opacity(0.1)),
                    in: Capsule()
                )
        }
    }
}

// MARK: - 分类按钮（仅本文件使用）

/// 分类按钮组件（复用于一级和二级分类）
private struct PickerCategoryButton: View {
    
    let category: Category
    let isSelected: Bool
    let action: () -> Void
    
    /// 分类图标视图：运行时用 UIImage(named:) 检测资源，兼容「CategoryIcons/xxx」与「xxx」；SVG 需 fill="#000000" 才能被模板着色
    @ViewBuilder
    private var categoryIconView: some View {
        let name = category.icon
        let withNamespace = "CategoryIcons/\(name)"
        let loaded = UIImage(named: withNamespace) ?? UIImage(named: name)
        if let img = loaded, name.hasPrefix("icon_") {
            Image(uiImage: img)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .foregroundColor(category.swiftUIColor)
        } else {
            Image(systemName: name.hasPrefix("icon_") ? "tag.fill" : name)
                .font(.system(size: 40, weight: .medium))
                .foregroundColor(category.swiftUIColor)
        }
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // 图标容器
                ZStack {
                    Circle()
                        .fill(category.swiftUIColor.opacity(0.1))
                        .frame(width: 64, height: 64)
                    
                    // 优先从 Asset Catalog 加载（先试命名空间路径，再试短名），找不到则用 SF Symbol
                    categoryIconView
                }
                .overlay(
                    Circle()
                        .stroke(
                            isSelected ? category.swiftUIColor : Color.clear,
                            lineWidth: 2
                        )
                )
                
                // 分类名称
                Text(category.name)
                    .font(.holoLabel)
                    .foregroundColor(isSelected ? category.swiftUIColor : .holoTextSecondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    CategoryPicker(
        selectedCategory: .constant(nil),
        transactionType: .constant(.expense)
    )
}
