//
//  AnalysisContextBuilder.swift
//  Holo
//
//  分析上下文构建分发器
//  根据领域分发到对应 Builder，crossModule 场景并发构建
//

import Foundation
import os.log

struct AnalysisContextBuilder {

    private static let logger = Logger(subsystem: "com.holo.app", category: "AnalysisContextBuilder")

    /// 构建分析上下文
    @MainActor
    func build(request: ResolvedAnalysisRequest) async -> AnalysisContext {
        switch request.domain {
        case .finance:
            let finance = await FinanceAnalysisContextBuilder().build(request: request)
            return AnalysisContext(
                domain: .finance,
                periodLabel: request.periodLabel,
                startDate: request.startDateString,
                endDate: request.endDateString,
                comparisonLabel: request.comparisonLabel,
                finance: finance,
                habit: nil,
                task: nil,
                thought: nil,
                crossModule: nil
            )

        case .habit:
            let habit = await HabitAnalysisContextBuilder().build(request: request)
            return AnalysisContext(
                domain: .habit,
                periodLabel: request.periodLabel,
                startDate: request.startDateString,
                endDate: request.endDateString,
                comparisonLabel: request.comparisonLabel,
                finance: nil,
                habit: habit,
                task: nil,
                thought: nil,
                crossModule: nil
            )

        case .task:
            let task = await TaskAnalysisContextBuilder().build(request: request)
            return AnalysisContext(
                domain: .task,
                periodLabel: request.periodLabel,
                startDate: request.startDateString,
                endDate: request.endDateString,
                comparisonLabel: request.comparisonLabel,
                finance: nil,
                habit: nil,
                task: task,
                thought: nil,
                crossModule: nil
            )

        case .thought:
            let thought = await ThoughtAnalysisContextBuilder().build(request: request)
            return AnalysisContext(
                domain: .thought,
                periodLabel: request.periodLabel,
                startDate: request.startDateString,
                endDate: request.endDateString,
                comparisonLabel: request.comparisonLabel,
                finance: nil,
                habit: nil,
                task: nil,
                thought: thought,
                crossModule: nil
            )

        case .crossModule:
            // 并发构建各模块
            async let f = FinanceAnalysisContextBuilder().build(request: request)
            async let h = HabitAnalysisContextBuilder().build(request: request)
            async let t = TaskAnalysisContextBuilder().build(request: request)
            async let th = ThoughtAnalysisContextBuilder().build(request: request)

            let (finance, habit, task, thought) = await (f, h, t, th)

            let crossModule = CrossModuleAnalysisContextBuilder().build(
                finance: finance,
                habit: habit,
                task: task,
                thought: thought
            )

            return AnalysisContext(
                domain: .crossModule,
                periodLabel: request.periodLabel,
                startDate: request.startDateString,
                endDate: request.endDateString,
                comparisonLabel: request.comparisonLabel,
                finance: finance,
                habit: habit,
                task: task,
                thought: thought,
                crossModule: crossModule
            )
        }
    }
}
