//
//  HoloContextPlanExecutionAdapter.swift
//  Holo
//
//  草案条目 → 现有 pending task 的执行适配（实施方案 §10）。
//
//  - 结构化映射：选中项直接转 task DTO，不把计划重新丢回意图识别模型。
//  - 幂等键 runID+draftRevision+itemID；已有成功回执跨 draftRevision 对账：
//    实质未变的事项复用 logicalItemID，不重复创建；实质改变生成变更候选。
//  - 保存前复查 accessGeneration/source revision/draftRevision（生成后被
//    忘记/更改的背景不能用于保存）。
//  - 纯逻辑核心可 standalone 测试；TaskRepository 写入在调用方。
//

import Foundation

// MARK: - 执行结果

nonisolated struct HoloContextPlanExecutionRequest: Equatable, Sendable {
    var runID: String
    var draftRevision: Int
    var items: [HoloContextPlanItem]
    var confirmedDates: [String: Date]
}

nonisolated struct HoloContextPlanExecutionOutcome: Equatable, Sendable {
    /// 待创建的条目（含标题/备注/确认日期映射）。
    var creations: [HoloContextPlanTaskCreation]
    /// 跨版本复用（已有成功回执且实质未变）：不重复创建。
    var reusedItemIDs: [String]
    /// 与既有任务内容相似：仅提示可能重复，不修改不合并。
    var possibleDuplicateTitles: [String]
}

nonisolated struct HoloContextPlanTaskCreation: Equatable, Sendable {
    /// 幂等键：runID+draftRevision+itemID。
    var idempotencyKey: String
    /// 逻辑项键：跨 draftRevision 对账（itemID 在 run 内稳定）。
    var logicalItemID: String
    var itemID: String
    var title: String
    var note: String?
    var dueDate: Date?
}

/// 单条创建的真实执行回执：回执以仓储写入结果为准，请求发出不算成功。
nonisolated struct HoloContextPlanCreationReceipt: Equatable, Sendable {
    var succeeded: Bool
    /// 成功时落库任务的真实 ID。
    var taskID: String?
    /// 失败时用户可读的原因。
    var failureMessage: String?

    static func success(taskID: String?) -> Self {
        .init(succeeded: true, taskID: taskID, failureMessage: nil)
    }

    static func failure(_ message: String) -> Self {
        .init(succeeded: false, taskID: nil, failureMessage: message)
    }
}

/// 真实回执对账结果：回执表只含真实落库项，成败计数以回执为准。
nonisolated struct HoloContextPlanReconciliation: Equatable, Sendable {
    /// existingReceipts + 本次新增成功项指纹。
    var updatedReceipts: [String: String]
    /// 本次有真实新增成功（需要持久化回执表）。
    var hasNewSuccesses: Bool
    var succeededCount: Int
    var failedCount: Int
}

nonisolated enum HoloContextPlanExecutionAdapter {
    /// 落库前复查（§10）：生成后被忘记/更改的背景不能继续用于保存。
    static func canSave(
        run: HoloPlanningRun,
        draftRevision: Int,
        currentGuard: HoloContextAccessGuard
    ) -> Bool {
        run.draftRevision == draftRevision
            && currentGuard.userDecisionVersion == run.accessGuard.userDecisionVersion
            && currentGuard.learningBaselineAt == run.accessGuard.learningBaselineAt
            && currentGuard.controls.allowsPlanningInjection
    }

    /// 把选中项转为创建请求（幂等+对账）。
    /// - Parameters:
    ///   - request: 草案执行请求（selected 条目+确认日期）。
    ///   - successfulReceipts: 已成功创建的回执（logicalItemID → 创建时的内容指纹）。
    ///   - existingTaskTitles: 既有任务标题集（相似性提示，不做合并）。
    static func prepare(
        request: HoloContextPlanExecutionRequest,
        successfulReceipts: [String: String],
        existingTaskTitles: Set<String>
    ) -> HoloContextPlanExecutionOutcome {
        var creations: [HoloContextPlanTaskCreation] = []
        var reused: [String] = []
        var duplicates: [String] = []

        for item in request.items where item.selected {
            let logicalKey = "\(request.runID)|\(item.itemID)"
            let fingerprint = contentFingerprint(item, confirmedDate: request.confirmedDates[item.itemID])
            // 跨版本对账：同一逻辑项已有成功回执且实质未变 → 复用，不重复创建。
            if let existingFingerprint = successfulReceipts[logicalKey],
               existingFingerprint == fingerprint {
                reused.append(item.itemID)
                continue
            }
            let creation = HoloContextPlanTaskCreation(
                idempotencyKey: "\(request.runID)|v\(request.draftRevision)|\(item.itemID)",
                logicalItemID: logicalKey,
                itemID: item.itemID,
                title: item.title,
                note: item.reason.isEmpty ? nil : item.reason,
                dueDate: request.confirmedDates[item.itemID]
            )
            creations.append(creation)
            // 内容相似的其他任务只能提示可能重复，不直接修改或合并。
            if existingTaskTitles.contains(normalizedTitle(item.title)) {
                duplicates.append(item.title)
            }
        }
        return HoloContextPlanExecutionOutcome(
            creations: creations,
            reusedItemIDs: reused,
            possibleDuplicateTitles: duplicates
        )
    }

    /// 条目内容指纹：实质改变（标题/日期变化）才算变更，编辑另一项不算。
    static func contentFingerprint(_ item: HoloContextPlanItem, confirmedDate: Date?) -> String {
        let datePart = confirmedDate.map { "\($0.timeIntervalSince1970)" } ?? "nil"
        return HoloContextSuppressionKeys.stableDigest("\(item.title)|\(datePart)")
    }

    /// 按真实回执对账（P0 门禁：失败不记回执、不虚报成功）。
    /// 只有真实落库的条目进入回执表；失败项留空，重试保存时按幂等规则重新创建。
    static func reconcileReceipts(
        creations: [HoloContextPlanTaskCreation],
        results: [String: HoloContextPlanCreationReceipt],
        existingReceipts: [String: String],
        items: [HoloContextPlanItem],
        confirmedDates: [String: Date]
    ) -> HoloContextPlanReconciliation {
        var updated = existingReceipts
        var succeededCount = 0
        for creation in creations where results[creation.idempotencyKey]?.succeeded == true {
            succeededCount += 1
            if let item = items.first(where: { $0.itemID == creation.itemID }) {
                updated[creation.logicalItemID] = contentFingerprint(
                    item,
                    confirmedDate: confirmedDates[item.itemID]
                )
            }
        }
        let failedCount = creations.count - succeededCount
        return HoloContextPlanReconciliation(
            updatedReceipts: updated,
            hasNewSuccesses: succeededCount > 0,
            succeededCount: succeededCount,
            failedCount: failedCount
        )
    }

    static func normalizedTitle(_ title: String) -> String {
        title.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
