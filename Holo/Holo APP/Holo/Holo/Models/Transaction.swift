//
//  Transaction.swift
//  Holo
//
//  交易记录实体类
//

import Foundation
import CoreData

/// 交易记录实体
@objc(Transaction)
public class Transaction: NSManagedObject {
    
    // MARK: - Properties
    
    @NSManaged public var id: UUID
    /// 金额（使用 NSDecimalNumber 以兼容 Core Data 的 decimal 属性）
    @NSManaged public var amount: NSDecimalNumber
    @NSManaged public var type: String
    @NSManaged public var date: Date
    @NSManaged public var note: String?
    @NSManaged public var remark: String?
    @NSManaged public var tags: [String]?
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
    @NSManaged public var category: Category?
    @NSManaged public var account: Account?

    // 分期记账字段
    @NSManaged public var installmentGroupId: UUID?
    @NSManaged public var installmentIndex: Int16
    @NSManaged public var installmentTotal: Int16

    // AI 来源标记
    @NSManaged public var isAICreated: Bool
    @NSManaged public var aiCandidate: String?
    /// AI 确认流程的来源消息 ID：确认中途被杀后启动对账用（实体已建但消息仍停在 confirming）
    @NSManaged public var aiSourceMessageId: String?
    /// AI 确认流程的来源 execution item ID（与 aiSourceMessageId 配对定位）
    @NSManaged public var aiSourceItemId: String?

    /// 由长期成本项目自动生成时，记录来源项目 ID
    @NSManaged public var spendingProjectId: UUID?
    /// 只有已实际发生的周期流水标为 confirmed；一次性购买不生成流水。
    @NSManaged public var projectPostingState: String?

    // 导入追踪：标记由哪次导入产生，用于按批次撤回
    @NSManaged public var importBatchId: UUID?
    /// 导入去重指纹（日期+金额+类型+分类+账户），用于检测重复导入
    @NSManaged public var importFingerprint: String?
    /// 导入时的 updatedAt 快照，撤回时判断用户是否编辑过
    @NSManaged public var importOriginalUpdatedAt: Date?
    /// 账单导入来源（wechat / alipay / bank:银行名 / csv），供列表筛选与对账
    @NSManaged public var importSource: String?
    /// 账单原始交易单号（微信/支付宝全局唯一），同源防重与追溯
    @NSManaged public var importSourceRef: String?

    // MARK: - Computed Properties

    /// 是否为分期交易
    var isInstallment: Bool { installmentGroupId != nil }

    /// 分期显示文字，如 "3/12期"；跨年分期会带上年份，如 "2027·11/12期"
    var installmentLabel: String? {
        guard isInstallment else { return nil }
        let calendar = Calendar.current
        let transactionYear = calendar.component(.year, from: date)
        let currentYear = calendar.component(.year, from: Date())
        let base = "\(installmentIndex)/\(installmentTotal)期"
        // 今年的期数保持简洁；明年及以后标注年份，避免长期分期看不出归属
        if transactionYear > currentYear {
            return "\(transactionYear)·\(base)"
        } else {
            return base
        }
    }
    
    /// 交易类型枚举
    var transactionType: TransactionType {
        TransactionType(rawValue: type) ?? .expense
    }
    
    /// 格式化金额（带符号）
    public var formattedAmountWithSign: String {
        let formatter = NumberFormatter.currency
        switch transactionType {
        case .income:
            return "+\(formatter.string(from: amount) ?? "")"
        case .expense:
            return "-\(formatter.string(from: amount) ?? "")"
        }
    }
    
    /// 格式化金额（不带符号）
    public var formattedAmount: String {
        NumberFormatter.currency.string(from: amount) ?? ""
    }
    
    /// 金额的 Decimal 形式（便于计算）
    public var amountAsDecimal: Decimal {
        amount as Decimal
    }
    
    // MARK: - Methods
    
    /// 删除交易
    public func delete() {
        managedObjectContext?.delete(self)
    }
}

// MARK: - Identifiable
/// 用于 SwiftUI sheet(item:) 等
extension Transaction: Identifiable {}
