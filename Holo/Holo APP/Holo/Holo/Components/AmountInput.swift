//
//  AmountInput.swift
//  Holo
//
//  金额输入组件
//  带数字键盘的金额输入器，支持大字体显示
//

import SwiftUI

/// 金额输入视图
struct AmountInput: View {
    
    // MARK: - Properties
    
    /// 输入的金额
    @Binding var amount: String
    
    /// 交易类型（收入/支出）
    @Binding var transactionType: TransactionType
    
    /// 占位符文字
    var placeholder: String = "0.00"
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: HoloSpacing.sm) {
            // 金额显示
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // 货币符号
                Text("¥")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(amount.isEmpty ? .holoTextSecondary : .holoTextPrimary)
                
                // 金额数字
                if amount.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 56, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                } else {
                    Text(amount)
                        .font(.system(size: 56, weight: .medium))
                        .foregroundColor(.holoTextPrimary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, HoloSpacing.lg)
            
            // 收支类型切换
            TransactionTypeSelector(transactionType: $transactionType)
        }
        .padding(HoloSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoGlassBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.lg)
                        .stroke(Color.holoBorder, lineWidth: 1)
                )
        )
    }
}

/// 交易类型选择器
struct TransactionTypeSelector: View {
    
    // MARK: - Properties
    
    /// 选中的交易类型
    @Binding var transactionType: TransactionType
    
    // MARK: - Body
    
    var body: some View {
        HStack(spacing: HoloSpacing.md) {
            // 支出按钮
            TypeButton(
                title: "支出",
                icon: "arrow.up.circle.fill",
                type: .expense,
                isSelected: transactionType == .expense,
                color: .holoPrimary
            ) {
                transactionType = .expense
            }
            
            // 收入按钮
            TypeButton(
                title: "收入",
                icon: "arrow.down.circle.fill",
                type: .income,
                isSelected: transactionType == .income,
                color: .holoSuccess
            ) {
                transactionType = .income
            }
        }
    }
}

/// 类型按钮
struct TypeButton: View {
    
    // MARK: - Properties
    
    /// 按钮标题
    let title: String
    
    /// 图标名称
    let icon: String
    
    /// 交易类型
    let type: TransactionType
    
    /// 是否选中
    let isSelected: Bool
    
    /// 强调色
    let color: Color
    
    /// 点击回调
    let action: () -> Void
    
    // MARK: - Body
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                
                Text(title)
                    .font(.holoLabel)
            }
            .foregroundColor(isSelected ? .white : .holoTextPrimary)
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.sm)
            .background(
                Capsule()
                    .fill(isSelected ? color : Color.holoGlassBackground)
                    .overlay(
                        Capsule()
                            .stroke(isSelected ? Color.clear : color, lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - Preview

#Preview {
    AmountInput(amount: .constant(""), transactionType: .constant(.expense))
}
