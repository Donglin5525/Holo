//
//  HoloMatterMutationPolicy.swift
//  Holo
//
//  权限分级（方案 §6/§11.5）：autoApply / needsConfirmation / reject
//
//  自动执行（必须可撤销）仅限：
//  - Matter 内用户明确语义、唯一对应、低风险的 Open Loop 状态更新
//  - 新增 AI 建议问题（落库恒 suggested，不打扰）
//  - 投影刷新
//  其余一律转确认；validator 拒绝的（如模型试图 confirm）直接 reject。
//

import Foundation

nonisolated enum HoloMatterMutationPolicy {

    nonisolated enum Decision: Equatable, Sendable {
        /// 自动应用（repository 落盘 + UI 轻回显 + 可撤销）。
        case autoApply
        /// 需要用户确认/回答（歧义追问、外部关联）。
        case needsConfirmation
        case reject(reason: String)
    }

    /// 对一个已通过 validator 的 proposal 做执行分级。
    static func decide(_ proposal: HoloMatterMutationProposal, context: HoloMatterMutationValidator.Context) -> Decision {
        // 歧义存在 → 不执行任何 mutation，先追问（方案 §3.2：不猜）。
        if !proposal.ambiguities.isEmpty {
            return .needsConfirmation
        }

        // addTask（2026-09-23 计划修订）恒需用户确认——往用户计划里加东西
        // 是显式动作，模型只能提议，不能落库。
        if proposal.mutations.contains(where: { if case .addTask = $0 { return true }; return false }) {
            return .needsConfirmation
        }

        // 走到这里，剩余 mutation 全部属于可自动执行类别：
        // addSuggestedOpenLoop / setOpenLoopState(resolved|waiting) / refreshProjection。
        // （空 mutations 的 proposal 只带 summary 建议，同样归为自动应用。）
        return .autoApply
    }
}
