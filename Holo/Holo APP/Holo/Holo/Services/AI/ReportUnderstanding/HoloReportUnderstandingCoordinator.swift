//
//  HoloReportUnderstandingCoordinator.swift
//  Holo
//
//  报告理解链路总协调（README §八）。
//  - 触发：报告持久化完成事件（回放通知 / agentReportDidFinalize）+ 冷启动重扫；
//    不依赖页面打开；通知丢失由台账重扫补偿（R28/R02）；
//  - 管线：台账认领（模型调用/写库前 100% 去重）→ 确定性提取 → 独立性裁决 →
//    统一仓库 upsert（observationKey=处理键）→ 台账终态 + 影子统计；
//  - 撤销：报告删除不即时挂钩——启动时对账档案存在性，缺档即撤销该报告证据
//    （无剩余证据 → suppressed 停用；尚有独立证据 → 保留并已按 lineageKey 去除，R20）。
//  - 线程：本工程默认 MainActor 隔离，管线整体 nonisolated（与 Extractor/Adapter/
//    Resolver 同口径），否则 Task.detached 一 await 就被拽回主线程；只有监听注册与
//    开关读取归主线程，各入口开头一次 hop 读齐开关快照后全程后台。
//

import CoreData
import Foundation
import OSLog

nonisolated enum HoloReportUnderstandingCoordinator {

    private static let logger = Logger(
        subsystem: "com.holo.app",
        category: "ReportUnderstanding"
    )

    static let sharedLedger = HoloReportUnderstandingLedger()
    @MainActor private static var observer: NSObjectProtocol?
    @MainActor private static var replayObserver: NSObjectProtocol?
    @MainActor private static var started = false

    /// 开关本体（HoloAIFeatureFlags）归主线程；管线各入口开头读一次快照，之后不再回主线程。
    private struct FlagSnapshot {
        let extraction: Bool
        let shadow: Bool
        let memoryWrite: Bool
    }

    @MainActor private static func flagSnapshot() -> FlagSnapshot {
        FlagSnapshot(
            extraction: HoloAIFeatureFlags.reportUnderstandingExtractionEnabled,
            shadow: HoloAIFeatureFlags.reportUnderstandingShadowEnabled,
            memoryWrite: HoloAIFeatureFlags.longTermMemoryWriteEnabled
        )
    }

    // MARK: - 启动与监听

    @MainActor static func startObserving() {
        guard !started else { return }
        started = true

        // 深度分析：finalizeAgentMessage 统一落点广播（本地+云端）
        observer = NotificationCenter.default.addObserver(
            forName: .agentReportDidFinalize,
            object: nil,
            queue: OperationQueue()
        ) { notification in
            guard let messageID = notification.userInfo?["messageID"] as? UUID,
                  let rendered = notification.userInfo?["rendered"] as? HoloRenderedAgentResult else { return }
            let descriptor = HoloReportSourceAdapter.analysisDescriptor(
                messageID: messageID.uuidString,
                rendered: rendered
            )
            let evidence = rendered.reportUnderstanding?.evidence ?? []
            Task.detached(priority: .utility) {
                await process(descriptor: descriptor, evidence: evidence)
            }
        }

        // 周期回放：本地与云端轨道共用 memoryInsightDidGenerate（云端无 cards 键，
        // payload 为同一真相源）
        replayObserver = NotificationCenter.default.addObserver(
            forName: .memoryInsightDidGenerate,
            object: nil,
            queue: OperationQueue()
        ) { notification in
            guard let insightID = notification.userInfo?["insightID"] as? String,
                  let payload = notification.userInfo?["payload"] as? MemoryInsightPayload,
                  let periodStart = notification.userInfo?["periodStart"] as? Date,
                  let periodEnd = notification.userInfo?["periodEnd"] as? Date else { return }
            let descriptor = HoloReportSourceAdapter.replayDescriptor(
                insightID: insightID,
                payload: payload,
                periodStart: periodStart,
                periodEnd: periodEnd,
                sourceSnapshotHash: nil
            )
            Task.detached(priority: .utility) {
                await process(descriptor: descriptor, evidence: replayEvidence(descriptor: descriptor))
            }
        }

        // 冷启动：重扫台账非终态条目 + 删除对账（崩溃窗口补偿）
        Task.detached(priority: .utility) {
            await rescanPending()
            await sweepRevocations()
        }
    }

    @MainActor static func stopObserving() {
        if let obs = observer { NotificationCenter.default.removeObserver(obs); observer = nil }
        if let obs = replayObserver { NotificationCenter.default.removeObserver(obs); replayObserver = nil }
        started = false
    }

    // MARK: - 处理管线

    static func process(
        descriptor: HoloReportDescriptor,
        evidence: [HoloReportEvidenceMaterial]
    ) async {
        let flags = await flagSnapshot()
        guard flags.extraction || flags.shadow else { return }
        // 用户记忆总开关为最高约束（R23 前置；写库前还有二次检查）
        guard flags.memoryWrite else { return }

        // 影子模式：只算不写（不动台账，避免污染正式认领）
        if flags.shadow && !flags.extraction {
            await runShadow(descriptor: descriptor, evidence: evidence)
            return
        }

        guard await sharedLedger.claim(descriptor: descriptor) else { return }

        let output = HoloReportFindingExtractor.extract(descriptor: descriptor, evidence: evidence)

        guard let repository = try? await HoloMemoryRuntime.shared.repository() else {
            await sharedLedger.markFailed(descriptor.processingKey, reason: "repository-unavailable")
            return
        }

        var increments: [HoloReportFindingIncrement: Int] = [:]
        var unknownIndependence = 0
        for record in output.records {
            let existing = try? await repository.fetch(id: record.id)
            let resolution = HoloReportEvidenceResolver.resolve(incoming: record, existing: existing)
            increments[resolution.increment, default: 0] += 1
            unknownIndependence += resolution.independenceUnknownCount
            guard resolution.shouldUpsert else { continue }
            // R23：提取后、写入前再核开关（用户可能在处理期间关闭自动记忆）
            let recheck = await flagSnapshot()
            guard recheck.memoryWrite, recheck.extraction else {
                await sharedLedger.markRejected(
                    descriptor.processingKey,
                    reason: "memory-switch-off-mid-flight"
                )
                return
            }
            do {
                _ = try await repository.upsert(
                    resolution.record,
                    observationKey: descriptor.processingKey
                )
            } catch {
                await sharedLedger.markDeferred(
                    descriptor.processingKey,
                    reason: "upsert-failed:\(String(describing: error))"
                )
                return
            }
        }

        let stats = HoloReportShadowStats(
            candidateCount: output.records.count,
            rejectedCount: output.rejections.count,
            duplicateOnlyCount: increments[.pureDuplicate] ?? 0,
            newEvidenceCount: increments[.newIndependentEvidence] ?? 0,
            newConditionCount: (increments[.conditionOrWindowChange] ?? 0) +
                (increments[.madeUsable] ?? 0),
            newPropositionCount: increments[.newProposition] ?? 0,
            rejectionReasons: output.rejections.map(\.reason)
        )
        await sharedLedger.markSucceeded(descriptor.processingKey, stats: stats)
        logger.info(
            "报告理解完成 \(descriptor.canonicalReportID, privacy: .public) 候选=\(output.records.count, privacy: .public) 拒绝=\(output.rejections.count, privacy: .public) 建议=\(output.suggestionCount, privacy: .public)"
        )
    }

    private static func runShadow(
        descriptor: HoloReportDescriptor,
        evidence: [HoloReportEvidenceMaterial]
    ) async {
        guard await flagSnapshot().memoryWrite else { return }
        let output = HoloReportFindingExtractor.extract(descriptor: descriptor, evidence: evidence)
        guard let repository = try? await HoloMemoryRuntime.shared.repository() else { return }
        var increments: [HoloReportFindingIncrement: Int] = [:]
        var unknown = 0
        for record in output.records {
            let existing = try? await repository.fetch(id: record.id)
            let resolution = HoloReportEvidenceResolver.resolve(incoming: record, existing: existing)
            increments[resolution.increment, default: 0] += 1
            unknown += resolution.independenceUnknownCount
        }
        logger.info(
            "[影子] \(descriptor.canonicalReportID, privacy: .public) 候选=\(output.records.count, privacy: .public) 纯重复=\(increments[.pureDuplicate] ?? 0, privacy: .public) 新证据=\(increments[.newIndependentEvidence] ?? 0, privacy: .public) 新命题=\(increments[.newProposition] ?? 0, privacy: .public) 独立性未知=\(unknown, privacy: .public) 拒绝=\(output.rejections.count, privacy: .public)"
        )
    }

    /// 旧链路写入权查询（HoloLongTermMemoryCandidateObserver 切换用，§九）：
    /// 该回放已由新链路成功处理时旧链路跳过，禁止双写晋升。
    static func ownsReplay(insightID: String) async -> Bool {
        guard await flagSnapshot().extraction else { return false }
        return await sharedLedger.isOwnedReport(canonicalReportID: "replay-\(insightID)")
    }

    // MARK: - 冷启动重扫（R28/R02）

    static func rescanPending() async {
        guard await flagSnapshot().extraction else { return }
        let candidates = await sharedLedger.rescanCandidates()
        guard !candidates.isEmpty else { return }
        logger.info("重扫报告理解台账：\(candidates.count, privacy: .public) 条")
        for entry in candidates {
            switch entry.sourceKind {
            case .periodReplay:
                if let (descriptor, evidence) = await loadReplayDescriptor(
                    insightID: entry.canonicalReportID
                        .replacingOccurrences(of: "replay-", with: "")
                ) {
                    await process(descriptor: descriptor, evidence: evidence)
                } else {
                    await sharedLedger.markRejected(
                        entry.processingKey,
                        reason: "rescan-source-missing"
                    )
                }
            case .deepAnalysis:
                if let (descriptor, evidence) = await loadAnalysisDescriptor(
                    messageID: entry.canonicalReportID
                        .replacingOccurrences(of: "analysis-", with: "")
                ) {
                    await process(descriptor: descriptor, evidence: evidence)
                } else {
                    await sharedLedger.markRejected(
                        entry.processingKey,
                        reason: "rescan-source-missing"
                    )
                }
            }
        }
    }

    // MARK: - 删除对账（R20/R22）

    /// 启动时对账：台账成功的报告若档案已删除 → 撤销该报告证据。
    static func sweepRevocations() async {
        guard await flagSnapshot().extraction else { return }
        guard let repository = try? await HoloMemoryRuntime.shared.repository() else { return }
        let entries = await sharedLedger.allSucceeded()
        guard !entries.isEmpty else { return }
        for entry in entries {
            if await archiveExists(entry: entry) { continue }
            logger.info("报告已删除，撤销证据：\(entry.canonicalReportID, privacy: .public)")
            await revoke(canonicalReportID: entry.canonicalReportID, repository: repository)
        }
    }

    /// 撤销一份报告的全部证据：无剩余证据的派生结论停用（suppressed），
    /// 尚有独立证据的保留；用户已有裁决的记录不动（用户裁决优先）。
    static func revoke(
        canonicalReportID: String,
        repository: CoreDataHoloMemoryRepository? = nil
    ) async {
        let repo: CoreDataHoloMemoryRepository
        if let repository {
            repo = repository
        } else if let runtimeRepo = try? await HoloMemoryRuntime.shared.repository() {
            repo = runtimeRepo
        } else {
            return
        }
        let prefix = "report-evidence:\(canonicalReportID):"
        guard let records = try? await repo.query(.all) else { return }
        for var record in records {
            guard record.userDecision == .none,
                  record.evidenceRefs.contains(where: { $0.lineageKey.hasPrefix(prefix) }) else { continue }
            record.evidenceRefs.removeAll { $0.lineageKey.hasPrefix(prefix) }
            record.recordVersion += 1
            record.updatedAt = Date()
            if record.evidenceRefs.isEmpty {
                // suppressed 允许空证据通过 Schema 校验（invalidated 不允许）
                record.state = .suppressed
            }
            try? await repo.replaceRecordForUserControl(record)
        }
    }

    private static func archiveExists(entry: HoloReportProcessingEntry) async -> Bool {
        switch entry.sourceKind {
        case .periodReplay:
            let insightID = entry.canonicalReportID.replacingOccurrences(of: "replay-", with: "")
            return await replayInsightExists(insightID: insightID)
        case .deepAnalysis:
            let messageID = entry.canonicalReportID.replacingOccurrences(of: "analysis-", with: "")
            return await agentMessageExists(messageID: messageID)
        }
    }

    // MARK: - 档案读取

    private static func loadReplayDescriptor(insightID: String) async -> (HoloReportDescriptor, [HoloReportEvidenceMaterial])? {
        guard let payload = await replayPayload(insightID: insightID) else { return nil }
        let descriptor = HoloReportSourceAdapter.replayDescriptor(
            insightID: insightID,
            payload: payload.payload,
            periodStart: payload.periodStart,
            periodEnd: payload.periodEnd,
            sourceSnapshotHash: payload.snapshotHash
        )
        return (descriptor, replayEvidence(descriptor: descriptor))
    }

    private static func replayEvidence(descriptor: HoloReportDescriptor) -> [HoloReportEvidenceMaterial] {
        // 回放卡证据为摘录型（无指标池）：按 claim 的证据引用合成材料
        var materials: [HoloReportEvidenceMaterial] = []
        for claim in descriptor.claims {
            for (index, evidenceID) in claim.evidenceIDs.enumerated() {
                materials.append(HoloReportEvidenceMaterial(
                    evidenceID: evidenceID,
                    kind: "rows",
                    metricKey: nil,
                    dataset: claim.domain.rawValue,
                    group: nil,
                    value: nil,
                    unit: nil,
                    sourceCount: claim.sampleCount,
                    count: nil,
                    excerpts: ["回放卡证据#\(index + 1)"]
                ))
            }
        }
        return materials
    }

    private static func loadAnalysisDescriptor(messageID: String) async -> (HoloReportDescriptor, [HoloReportEvidenceMaterial])? {
        guard let rendered = await agentRendered(messageID: messageID) else { return nil }
        let descriptor = HoloReportSourceAdapter.analysisDescriptor(
            messageID: messageID,
            rendered: rendered
        )
        return (descriptor, rendered.reportUnderstanding?.evidence ?? [])
    }

    private static func replayPayload(insightID: String) async -> (
        payload: MemoryInsightPayload, periodStart: Date, periodEnd: Date, snapshotHash: String?
    )? {
        await CoreDataStack.shared.waitUntilReady()
        let context = CoreDataStack.shared.newBackgroundContext()
        return await context.perform {
            guard let uuid = UUID(uuidString: insightID) else { return nil }
            let request = MemoryInsight.fetchRequest()
            request.predicate = NSPredicate(
                format: "id == %@ AND deletedAt == nil",
                uuid as CVarArg
            )
            request.fetchLimit = 1
            guard let insight = try? context.fetch(request).first,
                  let data = insight.cardsJSON.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(MemoryInsightPayload.self, from: data)
            else { return nil }
            return (payload, insight.periodStart, insight.periodEnd, insight.sourceSnapshotHash)
        }
    }

    private static func replayInsightExists(insightID: String) async -> Bool {
        await CoreDataStack.shared.waitUntilReady()
        let context = CoreDataStack.shared.newBackgroundContext()
        return await context.perform {
            guard let uuid = UUID(uuidString: insightID) else { return false }
            let request = MemoryInsight.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", uuid as CVarArg)
            request.fetchLimit = 1
            return (try? context.fetch(request).first) != nil
        }
    }

    private static func agentRendered(messageID: String) async -> HoloRenderedAgentResult? {
        await CoreDataStack.shared.waitUntilReady()
        let context = CoreDataStack.shared.newBackgroundContext()
        let json: String? = await context.perform {
            guard let uuid = UUID(uuidString: messageID) else { return nil }
            let request = ChatMessage.fetchRequest()
            request.predicate = NSPredicate(
                format: "id == %@ AND isStreaming == NO AND agentResultJSON != nil",
                uuid as CVarArg
            )
            request.fetchLimit = 1
            guard let message = try? context.fetch(request).first else { return nil }
            return message.agentResultJSON
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HoloRenderedAgentResult.self, from: data)
    }

    private static func agentMessageExists(messageID: String) async -> Bool {
        await CoreDataStack.shared.waitUntilReady()
        let context = CoreDataStack.shared.newBackgroundContext()
        return await context.perform {
            guard let uuid = UUID(uuidString: messageID) else { return false }
            let request = ChatMessage.fetchRequest()
            request.predicate = NSPredicate(
                format: "id == %@ AND agentResultJSON != nil",
                uuid as CVarArg
            )
            request.fetchLimit = 1
            return (try? context.fetch(request).first) != nil
        }
    }
}
