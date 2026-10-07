//
//  HoloMatterMutationValidator.swift
//  Holo
//
//  Proposal 校验（方案 §11.4/§12.2）：schema、来源 revision、ID 归属、越权动作。
//
//  校验失败一律 reject，不静默修正；stale proposal 可由上层基于新 snapshot 重跑一次。
//

import Foundation

nonisolated enum HoloMatterMutationValidator {

    nonisolated enum Outcome: Equatable, Sendable {
        case valid
        case rejected(reason: String)
    }

    /// 校验上下文：proposal 引用的一切 ID 必须真实存在于当前 Matter。
    nonisolated struct Context: Sendable {
        let matterID: UUID
        let currentRevision: Int64
        let knownOpenLoopIDs: Set<UUID>
        /// 当前计划任务标题（规范化），addTask 去重用（2026-09-23 计划修订）。
        var planTaskTitles: Set<String>

        init(
            matterID: UUID,
            currentRevision: Int64,
            knownOpenLoopIDs: Set<UUID>,
            planTaskTitles: Set<String> = []
        ) {
            self.matterID = matterID
            self.currentRevision = currentRevision
            self.knownOpenLoopIDs = knownOpenLoopIDs
            self.planTaskTitles = planTaskTitles
        }
    }

    /// addTask 去重口径：去空白 + 小写（与 Repository 事件键同风格）。
    nonisolated static func normalizedPlanTitle(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func validate(_ proposal: HoloMatterMutationProposal, context: Context) -> Outcome {
        // schema
        guard proposal.schemaVersion == HoloMatterMutationProposal.schemaVersion else {
            return .rejected(reason: "不支持的 schemaVersion \(proposal.schemaVersion)")
        }

        // 归属：proposal 必须指向当前 Matter
        guard proposal.matterID == context.matterID else {
            return .rejected(reason: "proposal 指向其他 Matter")
        }

        // revision：过期 proposal 拒绝（可基于新 snapshot 重算）
        guard proposal.baseMatterRevision == context.currentRevision else {
            return .rejected(reason: "proposal 基于 revision \(proposal.baseMatterRevision)，当前 \(context.currentRevision)")
        }

        for mutation in proposal.mutations {
            switch mutation {
            case .addSuggestedOpenLoop(let draft):
                if draft.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    return .rejected(reason: "addSuggestedOpenLoop 标题为空")
                }
            case .confirmOpenLoop(let openLoopID):
                // Prompt 层已禁止；再次到达即违规 reject
                guard context.knownOpenLoopIDs.contains(openLoopID) else {
                    return .rejected(reason: "confirmOpenLoop 引用未知 OpenLoop")
                }
                return .rejected(reason: "模型不得把 suggested 升为 confirmed")
            case .setOpenLoopState(let openLoopID, _):
                guard context.knownOpenLoopIDs.contains(openLoopID) else {
                    return .rejected(reason: "setOpenLoopState 引用未知 OpenLoop")
                }
            case .proposeLink(let draft):
                guard HoloMatterLinkEntityType.writable.contains(draft.entityType) else {
                    return .rejected(reason: "proposeLink 类型不在白名单")
                }
                if draft.entityID.trimmingCharacters(in: .whitespaces).isEmpty {
                    return .rejected(reason: "proposeLink entityID 为空")
                }
            case .addTask(let draft):
                // 计划修订（2026-09-23）：标题非空 + 计划内不得重复（方案 6.1 不输出重复任务）。
                let title = draft.title.trimmingCharacters(in: .whitespaces)
                if title.isEmpty {
                    return .rejected(reason: "addTask 标题为空")
                }
                if context.planTaskTitles.contains(Self.normalizedPlanTitle(title)) {
                    return .rejected(reason: "addTask 与计划内既有任务重复")
                }
            case .refreshProjection:
                break
            }
        }
        return .valid
    }
}
