//
//  FinanceDisplaySettings.swift
//  Holo
//
//  财务模块显示设置管理器
//  控制账本页月度卡片的显示/隐藏
//

import SwiftUI
import Combine

@MainActor
class FinanceDisplaySettings: ObservableObject {

    // MARK: - Singleton

    static let shared = FinanceDisplaySettings()

    // MARK: - Keys

    private let showExpenseKey = "financeDisplayShowMonthlyExpense"
    private let showIncomeKey = "financeDisplayShowMonthlyIncome"

    // MARK: - Properties

    /// 是否显示本月支出卡片（默认 true）
    @Published var showMonthlyExpense: Bool {
        didSet { UserDefaults.standard.set(showMonthlyExpense, forKey: showExpenseKey) }
    }

    /// 是否显示本月收入卡片（默认 false）
    @Published var showMonthlyIncome: Bool {
        didSet { UserDefaults.standard.set(showMonthlyIncome, forKey: showIncomeKey) }
    }

    // MARK: - Init

    private init() {
        // object(forKey:) 区分"未设置"和"显式 false"
        showMonthlyExpense = UserDefaults.standard.object(forKey: showExpenseKey) as? Bool ?? true
        showMonthlyIncome = UserDefaults.standard.object(forKey: showIncomeKey) as? Bool ?? false
    }
}
