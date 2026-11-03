//
//  HoloMemoryUserControlTransaction.swift
//  Holo
//
//  用户控制落库事务（方案 §11.4 / §11.5 / M03-b）
//
//  写前先行（write-ahead）三步：
//    ① 落控制事件（appliedAt = nil，限制意图先于记录状态持久化）
//    ② 按事件改写记录（replaceRecordForUserControl，绕过自动合并但走 Schema 校验）
//    ③ 回写事件 appliedAt
//  崩溃于任何一步：事件已持久化 → reconcile(outstanding:) 按幂等重放收敛，
//  「未完成限制意图仍被读取门禁识别」（§11.4）。②失败不会回滚①——这是设计
//  而非缺陷：宁可多留一条待重放的限制意图，不可丢一条用户控制。
//
//  M04 的控制服务在本事务之上组合：M03-a 预检（投影 allowedActions）→
//  版本校验 → 计算记录变更 → 调用本事务。
//

import Foundation

enum HoloMemoryUserControlTransactionError: Error, Equatable {
    /// 请求与记录不匹配或版本不符：不静默覆盖（§11.3 conflict）。
    case versionConflict(currentVersion: Int)
    case recordNotFound
    /// 事件写入失败：事务未产生任何效果。
    case eventPersistenceFailed
}

struct HoloMemoryUserControlTransaction: Sendable {
    let repository: any HoloMemoryRepository
    let eventStore: HoloMemoryControlEventStore

    init(
        repository: any HoloMemoryRepository,
        eventStore: HoloMemoryControlEventStore
    ) {
        self.repository = repository
        self.eventStore = eventStore
    }

    /// 执行一次控制落库。mutatedRecord 由调用方（M04 服务）按事件语义预先算好；
    /// 此处只负责：幂等 → 版本校验 → 写前先行三步。
    func apply(
        request: HoloMemoryUserControlRequest,
        mutatedRecord: HoloMemoryRecord,
        event: HoloMemoryUserControlEvent,
        now: Date
    ) async throws -> HoloMemoryUserControlOutcome {
        guard request.recordID == mutatedRecord.id else {
            throw HoloMemoryUserControlTransactionError.recordNotFound
        }
        guard let current = try await repository.fetch(id: request.recordID) else {
            return .notFound
        }
        guard current.recordVersion == request.expectedContentVersion else {
            return .conflict(currentContentVersion: current.recordVersion)
        }

        // ① 事件先落库（幂等：同 operationID 已存在 = 重试成功）。
        let inserted: Bool
        do {
            inserted = try await eventStore.append(event)
        } catch {
            throw HoloMemoryUserControlTransactionError.eventPersistenceFailed
        }
        guard inserted else {
            return .alreadyApplied
        }

        // ② 记录状态落库。失败时事件保留为待重放（限制意图不丢）。
        var recordToPersist = mutatedRecord
        recordToPersist.updatedAt = now
        try await repository.replaceRecordForUserControl(recordToPersist)

        // ③ 完成标记（失败无碍，reconcile 兜底）。
        try? await eventStore.markApplied(eventID: event.id, at: now)

        return .applied(
            newContentVersion: recordToPersist.recordVersion,
            undoableOperationID: request.operationID
        )
    }
}

// MARK: - 崩溃重放收敛器（§11.4「崩溃后按幂等事件重放」）

enum HoloMemoryControlEventReconciler {

    /// 重放全部待完成事件，返回收敛的事件数。
    /// 规则（只收紧不放宽，M03-a 代数为判据）：
    /// - 限制类事件（outdated/inaccurate/disabled/forgotten）：幂等写入目标状态；
    /// - 放宽类（confirmed/corrected）：仅当其 priorEventIDs 覆盖该记录全部限制事件时执行，
    ///   否则保持现状并标记完成（限制优先，不静默解除未见过的限制）；
    /// - restored/undo：M03-b 不盲放行（恢复需墓碑与校验链，属 M04 语义），
    ///   保持待完成状态直到 M04 服务接管——记录维持受限，方向保守。
    @discardableResult
    static func reconcile(
        outstanding: [HoloMemoryUserControlEvent],
        transaction: HoloMemoryUserControlTransaction,
        repository: any HoloMemoryRepository,
        now: Date = Date()
    ) async throws -> Int {
        let grouped = Dictionary(grouping: outstanding, by: \.targetRecordID)
        var settled = 0

        for (recordID, events) in grouped {
            let ordered = events.sorted { $0.occurredAt < $1.occurredAt }
            let allEvents = (try? await transaction.eventStore.events(forRecordID: recordID)) ?? []
            let restrictions = allEvents.filter { $0.kind.isUsageRestricting }

            for event in ordered {
                guard var record = try await repository.fetch(id: recordID) else {
                    // 记录已物理不存在：控制意图无从谈起，标记完成避免永久悬挂。
                    try? await transaction.eventStore.markApplied(eventID: event.id, at: now)
                    settled += 1
                    continue
                }

                switch event.kind {
                case .outdated:
                    record.state = .archived
                case .inaccurate, .disabled:
                    // 崩溃窗口可能落在「事件已落、墓碑未写」：重放一并补齐（§11.6）。
                    try await HoloMemoryUserControlService.ensureTombstone(
                        for: record, repository: repository, now: now
                    )
                    record.state = .suppressed
                    record.userDecision = .rejected
                case .forgotten:
                    try await HoloMemoryUserControlService.ensureTombstone(
                        for: record, repository: repository, now: now
                    )
                    record.state = .tombstoned
                    record.userDecision = .forgotten
                case .confirmed:
                    guard canLift(event: event, restrictions: restrictions) else {
                        try? await transaction.eventStore.markApplied(eventID: event.id, at: now)
                        settled += 1
                        continue
                    }
                    record.state = .active
                    record.userDecision = .confirmed
                case .corrected:
                    // 重放不携带新陈述正文（payloadDigest 只是指纹）：
                    // 记录已由事务②步写入新版本，重放只需收敛状态位。
                    guard canLift(event: event, restrictions: restrictions) else {
                        try? await transaction.eventStore.markApplied(eventID: event.id, at: now)
                        settled += 1
                        continue
                    }
                    record.state = .active
                    record.userDecision = .corrected
                case .restored, .undo:
                    continue // M04 服务接管；保持 outstanding，记录维持现状（保守）。
                }

                record.updatedAt = now
                try await repository.replaceRecordForUserControl(record)
                try? await transaction.eventStore.markApplied(eventID: event.id, at: now)
                settled += 1
            }
        }
        return settled
    }

    private static func canLift(
        event: HoloMemoryUserControlEvent,
        restrictions: [HoloMemoryUserControlEvent]
    ) -> Bool {
        HoloMemoryControlEventAlgebra.canLiftRestrictions(event, restrictions: restrictions)
    }
}
