//
//  BudgetStatus.swift
//  Holo
//
//  预算状态值类型 - 用于视图展示
//

import Foundation

/// 预算状态（不可变值类型）
struct BudgetStatus: Identifiable {
    let id: UUID              // budget.id
    let budget: Budget
    let budgetAmount: Decimal           // 原始预算额度
    let carryoverDeduction: Decimal     // 严格预算模式：上一期超支结转扣减（0 = 未开启或无结转）
    let effectiveAmount: Decimal        // 有效额度 = budgetAmount - carryoverDeduction（下限 0）
    let spentAmount: Decimal
    let remainingAmount: Decimal        // = effectiveAmount - spentAmount
    let progress: Double      // spentAmount / effectiveAmount
    let periodStartDate: Date
    let periodEndDate: Date
    let isOverBudget: Bool    // progress >= 1.0
    let isWarning: Bool       // progress >= 0.8
    let remainingDays: Int    // 距周期结束的天数
}

/// 首页预算总览（跨账户聚合）
struct GlobalBudgetSummary {
    let totalBudgetAmount: Decimal         // 各账户有效额度之和
    let totalOriginalAmount: Decimal       // 各账户原始预算之和
    let totalCarryoverDeduction: Decimal   // 结转扣减合计
    let totalSpentAmount: Decimal
    let totalRemainingAmount: Decimal
    let progress: Double
    let isOverBudget: Bool
    let isWarning: Bool
    let remainingDays: Int
}

/// 分类预算预警 chip 数据
struct CategoryBudgetWarning: Identifiable {
    let id = UUID()
    let categoryId: UUID?
    let categoryName: String
    let categoryIcon: String
    let categoryColor: String
    let progress: Double
    let isOverBudget: Bool
}
