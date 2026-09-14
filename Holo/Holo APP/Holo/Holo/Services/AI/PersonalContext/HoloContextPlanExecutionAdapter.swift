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

// MARK: - 回执 V2（今日看板 Matter 化方案 §8.2）

/// 带真实任务 ID 的执行回执：跨重启幂等 + Matter 补链依据。
/// Optional 只用于兼容 legacy；新写入的成功回执必须同时有 taskID/sourceMessageID。
nonisolated struct HoloContextPlanTaskReceiptV2: Codable, Equatable, Sendable {
    static let schemaVersion = 2

    let schemaVersion: Int
    let logicalItemID: String
    let fingerprint: String
    let taskID: UUID?
    let sourceMessageID: UUID?
    let sourceItemID: String
    let createdAt: Date

    init(
        logicalItemID: String,
        fingerprint: String,
        taskID: UUID?,
        sourceMessageID: UUID?,
        sourceItemID: String,
        createdAt: Date
    ) {
        self.schemaVersion = Self.schemaVersion
        self.logicalItemID = logicalItemID
        self.fingerprint = fingerprint
        self.taskID = taskID
        self.sourceMessageID = sourceMessageID
        self.sourceItemID = sourceItemID
        self.createdAt = createdAt
    }

    /// legacy 回执（只有指纹）转 V2 形态：能防重复，但没有任务 ID，不伪造 MatterLink。
    static func legacy(logicalItemID: String, fingerprint: String) -> Self {
        HoloContextPlanTaskReceiptV2(
            logicalItemID: logicalItemID,
            fingerprint: fingerprint,
            taskID: nil,
            sourceMessageID: nil,
            sourceItemID: logicalItemID.split(separator: "|").last.map(String.init) ?? logicalItemID,
            createdAt: .distantPast
        )
    }
}

/// 单项保存状态机（§8.1）：每个条目自己持有，互不影响。
nonisolated enum HoloContextPlanItemSaveState: Equatable, Sendable {
    case idle
    case saving
    /// 已加入，附真实任务 ID。
    case added(taskID: UUID)
    /// legacy 回执命中：已加入但任务 ID 未知（不伪造跳转/关联）。
    case addedLegacy
    /// 有 taskID 回执但任务已被删除：显示「原任务已删除，可重新加入」。
    case taskDeleted
    case failed(message: String)
    /// 权限阻断：背景被忘记/更改/闸关闭。
    case blocked
}

/// 单项 prepare 结果：要么创建，要么复用既有回执。
nonisolated enum HoloContextPlanSinglePreparation: Equatable, Sendable {
    case create(HoloContextPlanTaskCreation)
    /// 已加入；taskID 为 nil 表示 legacy 回执。
    case alreadyAdded(taskID: UUID?)
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

    // MARK: - 单项执行（§8.1：逐条即时加入，每项自己持有保存状态）

    /// 单项幂等判定：已有成功回执且实质未变 → 复用；否则产出创建请求。
    /// legacy 指纹命中同样防重复，但 taskID 为 nil（不伪造跳转/关联）。
    static func prepareSingleItem(
        item: HoloContextPlanItem,
        confirmedDate: Date?,
        runID: String,
        draftRevision: Int,
        legacyFingerprint: String?,
        receiptV2: HoloContextPlanTaskReceiptV2?,
        taskExists: Bool?
    ) -> HoloContextPlanSinglePreparation {
        let logicalKey = "\(runID)|\(item.itemID)"
        let fingerprint = contentFingerprint(item, confirmedDate: confirmedDate)

        // V2 回执：内容未变即复用；任务已删则允许重新创建（旧回执失效）。
        if let receipt = receiptV2, receipt.fingerprint == fingerprint {
            switch taskExists {
            case .some(false) where receipt.taskID != nil:
                break // 任务已删除 → 走重新创建
            default:
                return .alreadyAdded(taskID: receipt.taskID)
            }
        }
        // legacy 指纹：仍防重复（内容未变时），无 taskID。
        if receiptV2 == nil, let legacyFingerprint, legacyFingerprint == fingerprint {
            return .alreadyAdded(taskID: nil)
        }

        return .create(HoloContextPlanTaskCreation(
            idempotencyKey: "\(runID)|v\(draftRevision)|\(item.itemID)",
            logicalItemID: logicalKey,
            itemID: item.itemID,
            title: item.title,
            note: item.reason.isEmpty ? nil : item.reason,
            dueDate: confirmedDate
        ))
    }

    /// 回执展示状态判定（§8.2：任务被删除后回执不得让 UI 显示「已加入」）。
    static func resolveDisplayState(
        receipt: HoloContextPlanTaskReceiptV2?,
        taskExists: Bool?
    ) -> HoloContextPlanItemSaveState {
        guard let receipt else { return .idle }
        if let taskID = receipt.taskID {
            if taskExists == false { return .taskDeleted }
            return .added(taskID: taskID)
        }
        return .addedLegacy
    }

    /// 容量清理：按 createdAt 淘汰最旧（禁 Dictionary.keys.prefix 的非确定性淘汰）。
    static func trimReceipts(
        _ receipts: [String: HoloContextPlanTaskReceiptV2],
        limit: Int
    ) -> [String: HoloContextPlanTaskReceiptV2] {
        guard receipts.count > limit else { return receipts }
        let sorted = receipts.sorted { lhs, rhs in
            lhs.value.createdAt < rhs.value.createdAt
        }
        var result = receipts
        for (key, _) in sorted.prefix(receipts.count - limit) {
            result.removeValue(forKey: key)
        }
        return result
    }
}
