//
//  QuickTemplateView.swift
//  Holo
//
//  快速记账模板
//  提供常用的金额和分类组合，支持一键记账
//

import SwiftUI
import UIKit

/// 快速记账模板视图
struct QuickTemplateView: View {
    
    // MARK: - Properties
    
    private let repository = FinanceRepository.shared
    
    /// 选中的账户
    @Binding var selectedAccount: Account?
    
    /// 快速记账回调（金额、交易类型、选中的二级分类）
    let onQuickAdd: (Decimal, TransactionType, Category) -> Void
    
    /// 所有分类（含一级和二级）
    @State private var categories: [Category] = []
    
    /// 模板定义：每项通过分类名称匹配对应的二级子分类
    private let templates: [(amount: Decimal, categoryName: String, type: TransactionType)] = [
        (amount: 15,   categoryName: "早餐", type: .expense),
        (amount: 30,   categoryName: "午餐", type: .expense),
        (amount: 40,   categoryName: "晚餐", type: .expense),
        (amount: 5,    categoryName: "地铁", type: .expense),
        (amount: 25,   categoryName: "打车", type: .expense),
        (amount: 100,  categoryName: "日用", type: .expense),
        (amount: 200,  categoryName: "服饰", type: .expense),
        (amount: 50,   categoryName: "电影", type: .expense),
        (amount: 8000, categoryName: "工资", type: .income),
        (amount: 1000, categoryName: "奖金", type: .income),
    ]
    
    // MARK: - Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
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
                        if let category = findCategory(named: template.categoryName, type: template.type) {
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
        .background(Color.holoCardBackground)
        .task {
            await loadCategories()
        }
    }
    
    // MARK: - Methods
    
    @MainActor
    private func loadCategories() async {
        do {
            categories = try await repository.getAllCategories()
        } catch {
            print("加载分类失败：\(error.localizedDescription)")
        }
    }
    
    /// 按名称和类型查找二级子分类
    /// 优先匹配二级分类，找不到时回退到一级分类，仍找不到返回 nil
    private func findCategory(named name: String, type: TransactionType) -> Category? {
        let subCategory = categories.first {
            $0.name == name && $0.transactionType == type && $0.isSubCategory
        }
        if let found = subCategory { return found }
        
        return categories.first {
            $0.name == name && $0.transactionType == type
        }
    }
}

/// 快速模板中的分类图标（运行时检测 Asset，兼容 CategoryIcons/xxx 与 xxx）
@ViewBuilder
private func quickTemplateCategoryIcon(_ category: Category, size: CGFloat) -> some View {
    let name = category.icon
    let withNamespace = "CategoryIcons/\(name)"
    let loaded = UIImage(named: withNamespace) ?? UIImage(named: name)
    if let img = loaded, name.hasPrefix("icon_") {
        Image(uiImage: img)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    } else {
        Image(systemName: name.hasPrefix("icon_") ? "tag.fill" : name)
            .font(.system(size: size, weight: .medium))
    }
}

/// 快速模板按钮
struct QuickTemplateButton: View {
    
    let amount: Decimal
    let category: Category
    let type: TransactionType
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text("¥\(NSDecimalNumber(decimal: amount).intValue)")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(type == .expense ? .holoPrimary : .holoSuccess)
                
                HStack(spacing: 4) {
                    quickTemplateCategoryIcon(category, size: 20)
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
