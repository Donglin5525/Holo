//
//  AccountPicker.swift
//  Holo
//
//  账户选择器组件
//  用于选择支付账户（现金、微信、支付宝、信用卡等）
//

import SwiftUI
import CoreData

/// 账户选择器视图
/// 展示所有可用账户，支持点击选择
struct AccountPicker: View {
    
    // MARK: - Properties
    
    /// 当前选中的账户
    @Binding var selectedAccount: Account?
    
    /// 所有账户
    @State private var accounts: [Account] = []
    
    // MARK: - Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 标题
            Text("账户")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            
            // 账户列表
            VStack(spacing: HoloSpacing.sm) {
                ForEach(accounts, id: \.objectID) { account in
                    AccountRow(
                        account: account,
                        // 使用 objectID 比较，避免因 Core Data 模型字段不一致导致崩溃
                        isSelected: selectedAccount?.objectID == account.objectID
                    ) {
                        selectedAccount = account
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .task {
            await loadAccounts()
        }
    }
    
    // MARK: - Methods
    
    /// 加载账户数据（过滤归档账户）
    @MainActor
    private func loadAccounts() async {
        accounts = FinanceRepository.shared.getAccounts(includeArchived: false)
    }
}

/// 账户行组件
struct AccountRow: View {
    
    // MARK: - Properties
    
    /// 账户对象
    let account: Account
    
    /// 是否选中
    let isSelected: Bool
    
    /// 点击回调
    let action: () -> Void
    
    // MARK: - Body
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.md) {
                // 账户图标
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.holoPrimary.opacity(0.1) : Color.holoGlassBackground)
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: account.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isSelected ? Color.holoPrimary : Color.holoTextPrimary)
                }
                .overlay(
                    Circle()
                        .stroke(
                            isSelected ? Color.holoPrimary : Color.holoBorder,
                            lineWidth: 1
                        )
                )
                
                // 账户信息
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.holoBody)
                        .foregroundColor(isSelected ? Color.holoPrimary : Color.holoTextPrimary)

                    let balance = FinanceRepository.shared.getAccountBalance(account)
                    Text(formatBalance(balance))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(balance >= 0 ? .holoTextSecondary : .holoError)
                }
                
                Spacer()
                
                // 选中指示器
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color.holoPrimary)
                }
            }
            .padding(HoloSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(isSelected ? Color.holoPrimary.opacity(0.05) : Color.clear)
            )
        }
    }

    private func formatBalance(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "¥0.00"
    }
}

// MARK: - Preview

#Preview {
    AccountPicker(selectedAccount: .constant(nil))
}
