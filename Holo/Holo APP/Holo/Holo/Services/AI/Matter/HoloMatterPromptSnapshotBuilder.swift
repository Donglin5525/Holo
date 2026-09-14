//
//  HoloMatterPromptSnapshot.swift
//  Holo
//
//  普通回答生成前的 Matter 最小快照（今日看板 Matter 化方案 §8.6）
//
//  - 仅 scoped Chat 生效：MatterChatContextStore.active 存在且 Matter 可访问时构建；
//  - stale 投影的 summary/nextAction 不注入旧内容，只注入当前确定性状态；
//  - confirmed 与 suggested 分区，模型被告知 suggested 不是事实；
//  - 最多 10 条 active loops；不上传其他 Matter、整段历史或其他域原始数据。
//

import Foundation

nonisolated struct HoloMatterPromptLoop: Equatable, Sendable {
    let title: String
    let targetDate: Date?

    init(title: String, targetDate: Date? = nil) {
        self.title = title
        self.targetDate = targetDate
    }
}

nonisolated struct HoloMatterPromptSnapshot: Equatable, Sendable {
    let matterID: UUID
    let title: String
    let targetDate: Date?
    let phase: HoloMatterPhase?
    let revision: Int64
    /// 仅投影 fresh 时携带；stale 时为 nil（不把旧摘要当当前事实注入）。
    let summary: String?
    let confirmedOpenLoops: [HoloMatterPromptLoop]
    let suggestedOpenLoops: [HoloMatterPromptLoop]
    /// 仅 fresh 且带真实 entityID 时携带；stale 时不注入旧动作。
    let nextAction: HoloMatterPromptNextAction?

    init(
        matterID: UUID,
        title: String,
        targetDate: Date?,
        phase: HoloMatterPhase?,
        revision: Int64,
        summary: String?,
        confirmedOpenLoops: [HoloMatterPromptLoop],
        suggestedOpenLoops: [HoloMatterPromptLoop],
        nextAction: HoloMatterPromptNextAction?
    ) {
        self.matterID = matterID
        self.title = title
        self.targetDate = targetDate
        self.phase = phase
        self.revision = revision
        self.summary = summary
        self.confirmedOpenLoops = confirmedOpenLoops
        self.suggestedOpenLoops = suggestedOpenLoops
        self.nextAction = nextAction
    }
}

nonisolated struct HoloMatterPromptNextAction: Equatable, Sendable {
    let title: String
    let kind: HoloMatterNextAction.Kind

    init(title: String, kind: HoloMatterNextAction.Kind) {
        self.title = title
        self.kind = kind
    }
}

// MARK: - 构建

nonisolated enum HoloMatterPromptSnapshotBuilder {

    /// 单个 Matter 的最小快照。Matter 不可访问（已删等）返回 nil。
    @MainActor
    static func build(
        matterID: UUID,
        repository: HoloMatterRepository,
        now: Date = Date()
    ) -> HoloMatterPromptSnapshot? {
        guard let matter = repository.matter(id: matterID) else { return nil }
        let loops = repository.attentionLoopInputs(matterID: matterID)

        var confirmed: [HoloMatterPromptLoop] = []
        var suggested: [HoloMatterPromptLoop] = []
        for loop in loops where loop.state == .open || loop.state == .waiting {
            let entry = HoloMatterPromptLoop(title: loop.title, targetDate: loop.targetDate)
            if loop.epistemic == .confirmed {
                confirmed.append(entry)
            } else {
                suggested.append(entry)
            }
        }

        // 注入上限（§8.6：最多 10 条 active loops）。
        confirmed = Array(confirmed.prefix(10))
        suggested = Array(suggested.prefix(10))

        // 投影 stale 时不注入旧 summary/nextAction（§8.6：只注入当前确定性状态）。
        let projection = matter.projection
        let fresh = projection != nil && !matter.isProjectionStale
            && projection?.sourceMatterRevision == matter.revision

        let nextAction: HoloMatterPromptNextAction?
        if fresh, let next = projection?.nextAction, next.kind != .suggestion {
            nextAction = HoloMatterPromptNextAction(title: next.title, kind: next.kind)
        } else {
            nextAction = nil
        }

        return HoloMatterPromptSnapshot(
            matterID: matter.id,
            title: matter.title,
            targetDate: matter.targetDate,
            phase: matter.phase,
            revision: matter.revision,
            summary: fresh ? projection?.summary : nil,
            confirmedOpenLoops: confirmed,
            suggestedOpenLoops: suggested,
            nextAction: nextAction
        )
    }
}