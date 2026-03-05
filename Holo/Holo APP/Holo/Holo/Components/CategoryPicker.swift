//
//  CategoryPicker.swift
//  Holo
//
//  分类选择器组件
//  用于选择交易分类，支持收入/支出类型切换
//

import SwiftUI
import CoreData

/// 分类选择器视图
/// 展示所有可用分类，支持点击选择
struct CategoryPicker: View {
    
    // MARK: - Properties
    
    /// 当前选中的分类
    @Binding var selectedCategory: Category?
    
    /// 交易类型（收入/支出）
    var transactionType: TransactionType
    
    /// 所有分类
    @State private var categories: [Category] = []
    
    // MARK: - Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 标题
            Text("分类")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            
            // 分类网格
            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ],
                spacing: HoloSpacing.md
            ) {
                ForEach(categories.filter { $0.transactionType == transactionType }, id: \.objectID) { category in
                    CategoryButton(
                        category: category,
                        // 使用 objectID 作为唯一标识，避免因模型字段差异导致访问 id 崩溃
                        isSelected: selectedCategory?.objectID == category.objectID
                    ) {
                        selectedCategory = category
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .task {
            await loadCategories()
        }
    }
    
    // MARK: - Methods
    
    /// 加载分类数据
    @MainActor
    private func loadCategories() async {
        do {
            categories = try await FinanceRepository.shared.getAllCategories()
        } catch {
            print("加载分类失败：\(error.localizedDescription)")
        }
    }
}

/// 分类按钮组件
struct CategoryButton: View {
    
    // MARK: - Properties
    
    /// 分类对象
    let category: Category
    
    /// 是否选中
    let isSelected: Bool
    
    /// 点击回调
    let action: () -> Void
    
    // MARK: - Body
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // 图标容器
                ZStack {
                    Circle()
                        .fill(category.swiftUIColor.opacity(0.1))
                        .frame(width: 48, height: 48)
                    
                    Image(systemName: category.icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(category.swiftUIColor)
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
            }
        }
    }
}

// MARK: - Preview

#Preview {
    CategoryPicker(
        selectedCategory: .constant(nil),
        transactionType: .expense
    )
}
