//
//  QuickTemplateView.swift
//  Holo
//
//  快速记账模板
//  提供常用的金额和分类组合，支持一键记账
//

import SwiftUI

/// 快速记账模板视图
struct QuickTemplateView: View {
    
    // MARK: - Properties
    
    /// 数据仓库
    private let repository = FinanceRepository.shared
    
    /// 选中的账户
    @Binding var selectedAccount: Account?
    
    /// 快速记账回调
    let onQuickAdd: (Decimal, TransactionType, Category) -> Void
    
    /// 所有分类
    @State private var categories: [Category] = []
    
    /// 常用模板
    private let templates: [(amount: Decimal, categoryIndex: Int, type: TransactionType)] = [
        // 早餐 - 15 元
        (amount: 15, categoryIndex: 0, type: .expense),
        // 午餐 - 30 元
        (amount: 30, categoryIndex: 0, type: .expense),
        // 晚餐 - 40 元
        (amount: 40, categoryIndex: 0, type: .expense),
        // 地铁 - 5 元
        (amount: 5, categoryIndex: 1, type: .expense),
        // 打车 - 25 元
        (amount: 25, categoryIndex: 1, type: .expense),
        // 超市 - 100 元
        (amount: 100, categoryIndex: 2, type: .expense),
        // 网购 - 200 元
        (amount: 200, categoryIndex: 2, type: .expense),
        // 电影 - 50 元
        (amount: 50, categoryIndex: 3, type: .expense),
        // 工资 - 8000 元
        (amount: 8000, categoryIndex: 0, type: .income),
        // 奖金 - 1000 元
        (amount: 1000, categoryIndex: 3, type: .income)
    ]
    
    // MARK: - Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题
            HStack {
                Text("快速记账")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
                
                Spacer()
                
                Text("常用金额")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
            
            // 模板网格（只有在有分类数据时才展示）
            if !categories.isEmpty {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ],
                    spacing: HoloSpacing.sm
                ) {
                    ForEach(templates.indices, id: \.self) { index in
                        let template = templates[index]
                        if let category = getCategory(for: template) {
                            QuickTemplateButton(
                                amount: template.amount,
                                category: category,
                                type: template.type
                            ) {
                                onQuickAdd(template.amount, template.type, category)
                            }
                        }
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.white)
        .task {
            await loadCategories()
        }
    }
    
    // MARK: - Methods
    
    /// 加载分类数据
    @MainActor
    private func loadCategories() async {
        do {
            categories = try await repository.getAllCategories()
        } catch {
            print("加载分类失败：\(error.localizedDescription)")
        }
    }
    
    /// 获取分类
    /// 当目标类型下没有任何分类时，返回 nil，调用方自行跳过该模板，避免越界崩溃
    private func getCategory(for template: (amount: Decimal, categoryIndex: Int, type: TransactionType)) -> Category? {
        let filteredCategories = categories.filter { $0.transactionType == template.type }
        guard !filteredCategories.isEmpty else {
            return nil
        }
        let index = template.categoryIndex % filteredCategories.count
        return filteredCategories[index]
    }
}

/// 快速模板按钮
struct QuickTemplateButton: View {
    
    // MARK: - Properties
    
    /// 金额
    let amount: Decimal
    
    /// 分类
    let category: Category
    
    /// 交易类型
    let type: TransactionType
    
    /// 点击回调
    let action: () -> Void
    
    // MARK: - Body
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // 金额
                Text("¥\(NSDecimalNumber(decimal: amount).intValue)")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(type == .expense ? .holoPrimary : .holoSuccess)
                
                // 分类
                HStack(spacing: 4) {
                    Image(systemName: category.icon)
                        .font(.system(size: 10, weight: .medium))
                    
                    Text(category.name)
                        .font(.holoTinyLabel)
                }
                .foregroundColor(.holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(Color.holoBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .stroke(Color.holoBorder, lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - Preview

#Preview {
    QuickTemplateView(selectedAccount: .constant(nil)) { _, _, _ in
        print("Quick add")
    }
}
