//
//  FinancePeriodSettings.swift
//  Holo
//
//  全局记账周期设置
//
//  控制整个财务模块"一个月"的起始日。
//  默认为 1（= 自然月，向后兼容），用户可改为 1-31 的任意值。
//  改了之后，统计页、账户详情"本期"、预算默认起始日都按此周期计算。
//

import SwiftUI
import Combine

@MainActor
final class FinancePeriodSettings: ObservableObject {

    // MARK: - Singleton

    static let shared = FinancePeriodSettings()

    // MARK: - Keys

    private nonisolated static let cycleStartDayKey = "financePeriodBillingCycleStartDay"

    // MARK: - Properties

    /// 记账周期起始日（1-31），默认 1（自然月）
    @Published var billingCycleStartDay: Int {
        didSet {
            let clamped = min(max(billingCycleStartDay, 1), 31)
            if clamped != billingCycleStartDay {
                billingCycleStartDay = clamped
            }
            UserDefaults.standard.set(billingCycleStartDay, forKey: Self.cycleStartDayKey)
        }
    }

    // MARK: - Init

    private init() {
        // object(forKey:) 区分"未设置"和"显式设为 1"
        let stored = UserDefaults.standard.object(forKey: Self.cycleStartDayKey) as? Int
        billingCycleStartDay = stored.map { min(max($0, 1), 31) } ?? 1
    }

    /// 非隔离读取记账周期起始日（AI 分析链路等非主线程上下文用；与 UI 同一存储）
    nonisolated static var storedBillingCycleStartDay: Int {
        let stored = UserDefaults.standard.object(forKey: cycleStartDayKey) as? Int
        return stored.map { min(max($0, 1), 31) } ?? 1
    }

    // MARK: - 计算辅助

    /// 当前账单周期范围 [start, end)，包含参考日期（默认 now）
    func currentCycleRange(reference: Date = Date()) -> (start: Date, end: Date) {
        BillingCycleCalculator.currentCycleRange(
            startDay: billingCycleStartDay,
            reference: reference
        )
    }

    /// 当前周期的起始日
    var currentCycleStart: Date {
        currentCycleRange().start
    }

    /// 是否为自然月模式（起始日 = 1）
    var isNaturalMonth: Bool {
        billingCycleStartDay == 1
    }
}
