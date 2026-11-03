//
//  GoalWorkshopCandidateBuilder.swift
//  Holo
//
//  目标闭环·授权候选构建（最终规格 §3.1 / R06）
//
//  会话开始时从原模块读取「可供复用」的既有对象摘要（名称/类型/单位），不读任何记录；
//  随会话落库，模型只能引用其中 ID。信用卡等负债账户带标记，不可被默认为专款来源。
//

import Foundation

@MainActor
enum GoalWorkshopCandidateBuilder {

    static func build(habitRepository: HabitRepository = .shared,
                      financeRepository: FinanceRepository = .shared) -> GoalWorkshopAuthorizedCandidates {
        let habits = habitRepository.activeHabits
            .filter { $0.deletedAt == nil && !$0.isArchived }
            .map {
                GoalWorkshopHabitCandidate(
                    id: $0.id,
                    name: $0.name,
                    type: $0.isNumericType ? "numeric" : "checkIn",
                    unit: $0.unit,
                    aggregation: $0.isCountType ? "sum" : "latest",
                    isBadHabit: $0.isBadHabit
                )
            }
        let accounts = financeRepository.getAccounts(includeArchived: false)
            .filter { $0.deletedAt == nil }
            .map {
                GoalWorkshopAccountCandidate(
                    id: $0.id,
                    name: $0.name,
                    type: $0.type,
                    isCreditLiability: $0.accountType == .creditCard
                )
            }
        return GoalWorkshopAuthorizedCandidates(habits: habits, accounts: accounts)
    }
}
