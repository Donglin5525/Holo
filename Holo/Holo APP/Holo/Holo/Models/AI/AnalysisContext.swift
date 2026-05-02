//
//  AnalysisContext.swift
//  Holo
//
//  AI 分析查询的通用上下文模型
//  持久化到 Core Data，用于卡片渲染和 LLM 注入
//

import Foundation

/// 通用分析上下文，每个领域最多填充一个子上下文
struct AnalysisContext: Codable, Equatable, Sendable {
    let domain: AnalysisDomain
    let periodLabel: String
    let startDate: String
    let endDate: String
    let comparisonLabel: String?
    let finance: FinanceAnalysisContext?
    let habit: HabitAnalysisContext?
    let task: TaskAnalysisContext?
    let thought: ThoughtAnalysisContext?
    let crossModule: CrossModuleAnalysisContext?

    /// 所有领域 context 都为 nil 或其数据全为零值时视为空
    var isEmpty: Bool {
        let hasFinance = finance != nil && !finance!.isDataFree
        let hasHabit = habit != nil && !habit!.isDataFree
        let hasTask = task != nil && !task!.isDataFree
        let hasThought = thought != nil && !thought!.isDataFree
        let hasCrossModule = crossModule != nil && !crossModule!.isDataFree
        return !hasFinance && !hasHabit && !hasTask && !hasThought && !hasCrossModule
    }
}
