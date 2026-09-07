//
//  HoloContextPlanningCoordinator.swift
//  Holo
//
//  通用个人情境的规划运行协调（实施方案 §8）。
//
//  有限状态机：preparing → retrieving → generating → draftReady / needsInput /
//  failed / cancelled。不建无限自主循环：
//  - 每 run 最多 2 次生成（§11），最多 1 次原文补查（§7.1）。
//  - 生成回调核对 runID + requestRevision + accessGeneration；取消/过期后不落新草案。
//  - 校验失败允许一次结构修复再生成；仍失败给基础回答并说明无法可靠使用的部分。
//  - 依赖协议注入（生成/检索/持久化/控制快照），可 standalone 测试。
//

import Foundation

// MARK: - 依赖协议

nonisolated protocol HoloContextPlanGenerating: Sendable {
    func generate(prompt: String) async throws -> String
}

nonisolated protocol HoloPlanningRunPersisting: Sendable {
    func saveRun(_ run: HoloPlanningRun) async throws
    /// 回调核对用：重新读取当前运行状态（取消/追问可能已改变）。
    func loadRun(runID: String) async throws -> HoloPlanningRun?
    func saveDraft(_ draft: HoloContextPlanDraft) async throws
}

/// 一次原文补查提供方（P7 入口接线实现；返回段并入生成 prompt）。
nonisolated protocol HoloContextRawFallbackProviding: Sendable {
    func rawSegments(
        for result: HoloContextRetrievalResult,
        frame: HoloPlanningRequestFrame
    ) async throws -> [HoloContextSegment]
}

// MARK: - 协调器

nonisolated struct HoloContextPlanningCoordinator: Sendable {
    /// 每 run 生成上限（§11：planning 继承 chat 池且每 run 最多 2 次生成）。
    static let generationBudget = 2
    /// 每 run 原文补查上限（§7.1）。
    static let rawFallbackBudget = 1

    let generator: any HoloContextPlanGenerating
    let retrieval: HoloContextRetrievalService
    let persistence: any HoloPlanningRunPersisting
    let rawFallback: (any HoloContextRawFallbackProviding)?
    /// 政策筛选前的候选记录来源（P2 HoloContextAccessPolicy 在此应用）。
    let recordsProvider: @Sendable () async throws -> [HoloMemoryRecord]
    /// 控制快照（版本/基线/闸），生成前后核对。
    let controlSnapshotProvider: @Sendable () async throws -> HoloContextAccessGuard
    let calendar: Calendar

    init(
        generator: any HoloContextPlanGenerating,
        retrieval: HoloContextRetrievalService,
        persistence: any HoloPlanningRunPersisting,
        rawFallback: (any HoloContextRawFallbackProviding)? = nil,
        recordsProvider: @Sendable @escaping () async throws -> [HoloMemoryRecord],
        controlSnapshotProvider: @Sendable @escaping () async throws -> HoloContextAccessGuard,
        calendar: Calendar = .current
    ) {
        self.generator = generator
        self.retrieval = retrieval
        self.persistence = persistence
        self.rawFallback = rawFallback
        self.recordsProvider = recordsProvider
        self.controlSnapshotProvider = controlSnapshotProvider
        self.calendar = calendar
    }

    enum PlanningError: Error, Equatable {
        /// 控制闸关闭（检索/注入任一不可用）。
        case gateClosed
        /// 运行已取消/被追问取代：迟到结果丢弃。
        case staleRun
        /// 权限代际变化：结果不可用。
        case generationChanged
        /// 生成预算耗尽后仍不可交付：返回基础回答路径的信号。
        case undeliverableAfterRepair
    }

    struct Outcome: Equatable, Sendable {
        var run: HoloPlanningRun
        var draft: HoloContextPlanDraft
        var retrievalResult: HoloContextRetrievalResult
        var rawFallbackUsed: Bool
        var repaired: Bool
    }

    // MARK: 主流程

    /// 发起一轮规划（新 run）。frame 来自意图识别或显式入口。
    func start(
        frame: HoloPlanningRequestFrame,
        parentMessageID: String? = nil,
        now: Date = Date()
    ) async throws -> Outcome {
        try await runFlow(
            frame: frame,
            parentMessageID: parentMessageID,
            existingRun: nil,
            now: now
        )
    }

    /// 同一 run 的追问：requestRevision +1，frame 更新并重新判定适用性。
    func followUp(
        run: HoloPlanningRun,
        updatedFrame: HoloPlanningRequestFrame,
        now: Date = Date()
    ) async throws -> Outcome {
        guard run.state != .cancelled else { throw PlanningError.staleRun }
        var revised = run
        revised.requestRevision += 1
        revised.state = .preparing
        revised.updatedAt = now
        try await persistence.saveRun(revised)
        return try await runFlow(
            frame: updatedFrame,
            parentMessageID: revised.parentMessageID,
            existingRun: revised,
            now: now
        )
    }

    /// 取消：终态化；进行中的迟到结果将被丢弃。
    func cancel(runID: String, now: Date = Date()) async throws {
        guard var run = try await persistence.loadRun(runID: runID) else { return }
        run.state = .cancelled
        run.updatedAt = now
        try await persistence.saveRun(run)
    }

    // MARK: 内部流程

    private func runFlow(
        frame: HoloPlanningRequestFrame,
        parentMessageID: String?,
        existingRun: HoloPlanningRun?,
        now: Date
    ) async throws -> Outcome {
        // 0) 控制闸（检索+注入都必须可用；retrieval 开 injection 关是 shadow 计数，
        //    不产生用户可见草案）。
        let guardSnapshot = try await controlSnapshotProvider()
        let injectionGate: (HoloPersonalContextControlSnapshot) -> Bool = { $0.allowsPlanningInjection }
        _ = injectionGate
        guard guardSnapshot.controls.allowsPlanningInjection else {
            throw PlanningError.gateClosed
        }

        var run = existingRun ?? HoloPlanningRun(
            parentMessageID: parentMessageID,
            frame: frame,
            accessGuard: guardSnapshot,
            createdAt: now,
            updatedAt: now
        )
        run.frame = frame
        run.state = .retrieving
        run.updatedAt = now
        try await persistence.saveRun(run)

        // 1) 政策筛选 + 混合检索。
        let records = try await recordsProvider()
        let policy = HoloContextAccessPolicy.selectAdviceCandidates(records: records)
        let retrievalResult = await retrieval.retrieve(
            frame: frame,
            catalog: policy.selected,
            calendar: calendar,
            now: now
        )

        // 2) 一次原文补查（缺口重要时；预算 1）。
        var fallbackSegments: [HoloContextSegment] = []
        var rawFallbackUsed = false
        if run.rawFallbacksUsed < Self.rawFallbackBudget,
           let rawFallback,
           retrievalResult.selected.count < 2 || retrievalResult.semanticCoverage == .degraded {
            let segments = (try? await rawFallback.rawSegments(for: retrievalResult, frame: frame)) ?? []
            let budgeted = Array(segments.prefix(HoloContextRetrievalService.rawFallbackSegmentLimit))
            var used = 0
            for segment in budgeted {
                used += segment.text.utf16.count
                if used > HoloContextRetrievalService.rawFallbackCharacterLimit { break }
                fallbackSegments.append(segment)
            }
            rawFallbackUsed = !fallbackSegments.isEmpty
            run.rawFallbacksUsed += rawFallbackUsed ? 1 : 0
        }

        // 3) 生成（≤2 次：首生成 + 一次修复）。
        run.state = .generating
        run.updatedAt = now
        try await persistence.saveRun(run)

        var lastFindings: [HoloContextPlanValidator.Finding] = []
        var deliverable: HoloContextPlanDraft?
        var repaired = false
        while run.generationsUsed < Self.generationBudget {
            // 回调核对：取消/追问取代 → 丢弃。
            guard let current = try await persistence.loadRun(runID: run.runID),
                  current.runID == run.runID,
                  current.requestRevision == run.requestRevision,
                  current.state != .cancelled
            else {
                throw PlanningError.staleRun
            }

            let raw = try await generator.generate(
                prompt: Self.planPrompt(
                    frame: frame,
                    selected: retrievalResult.selected,
                    fallbackSegments: fallbackSegments,
                    semanticCoverage: retrievalResult.semanticCoverage
                )
            )
            // 生成返回后复查：取消/追问可能在生成在途时发生（§8.1 取消后不落新草案）。
            guard let afterGenerate = try await persistence.loadRun(runID: run.runID),
                  afterGenerate.runID == run.runID,
                  afterGenerate.requestRevision == run.requestRevision,
                  afterGenerate.state != .cancelled
            else {
                throw PlanningError.staleRun
            }
            run.generationsUsed += 1
            run.updatedAt = now

            // 解析/校验失败计入预算内修复：一次结构修复后再生（§8.3），
            // 不得把「JSON 恰好解析成功」当语义通过，也不让单次失败直接抛穿。
            do {
                let parsed = try HoloContextPlanDraftParser.parse(
                    raw,
                    runID: run.runID,
                    draftRevision: run.draftRevision + 1
                )
                let (sanitized, findings) = HoloContextPlanValidator.validate(
                    draft: parsed,
                    availableContexts: retrievalResult.selected
                )
                lastFindings = findings
                if HoloContextPlanValidator.isDeliverable(findings: findings) {
                    deliverable = sanitized
                    break
                }
            } catch {
                lastFindings = [HoloContextPlanValidator.Finding(code: .emptyAnswer, detail: "解析失败：\(error)")]
            }
            if run.generationsUsed < Self.generationBudget {
                repaired = true // 允许一次结构修复再生成（§8.3）
            }
        }

        guard var draft = deliverable else {
            run.state = .failed
            run.updatedAt = now
            try await persistence.saveRun(run)
            throw PlanningError.undeliverableAfterRepair
        }

        // 4) 落库前代际复查（保存前再次核对 accessGeneration；§10）。
        let finalGuard = try await controlSnapshotProvider()
        guard finalGuard.userDecisionVersion == run.accessGuard.userDecisionVersion,
              finalGuard.learningBaselineAt == run.accessGuard.learningBaselineAt,
              finalGuard.controls.allowsPlanningInjection
        else {
            run.state = .failed
            run.updatedAt = now
            try await persistence.saveRun(run)
            throw PlanningError.generationChanged
        }

        // 5) 草案就绪。
        run.state = .draftReady
        run.draftRevision = draft.draftRevision
        run.updatedAt = now
        try await persistence.saveRun(run)
        draft.coverage.readSources = Array(Set(draft.coverage.readSources))
        // 依据快照回填（P0：依据区展示本机命题原文，非模型复述；随草案固化）。
        draft.basisEntries = Self.basisEntries(for: draft, from: retrievalResult.selected)
        try await persistence.saveDraft(draft)
        _ = lastFindings
        return Outcome(
            run: run,
            draft: draft,
            retrievalResult: retrievalResult,
            rawFallbackUsed: rawFallbackUsed,
            repaired: repaired
        )
    }

    // MARK: - 生成 Prompt

    /// 依据快照（P0）：只取草案实际采用的情境条目，固化本机命题与状态。
    static func basisEntries(
        for draft: HoloContextPlanDraft,
        from entries: [HoloContextCatalogEntry]
    ) -> [HoloContextPlanBasisEntry] {
        let used = Set(draft.usedContextRefs)
        return entries
            .filter { used.contains($0.payload.contextID) }
            .map { entry in
                HoloContextPlanBasisEntry(
                    contextID: entry.payload.contextID,
                    statement: entry.payload.statement,
                    epistemicStatus: entry.payload.epistemicStatus.rawValue,
                    occurrenceStatus: entry.currentOccurrenceStatus?.rawValue
                )
            }
    }

    /// 规划 prompt：目标框架 + 已选情境 + 补查原文 + 覆盖状态。
    static func planPrompt(
        frame: HoloPlanningRequestFrame,
        selected: [HoloContextCatalogEntry],
        fallbackSegments: [HoloContextSegment],
        semanticCoverage: HoloContextSemanticCoverage
    ) -> String {
        var contextLines: [String] = []
        for entry in selected {
            var fields = "\"contextID\":\(jsonString(entry.payload.contextID))"
            fields += ",\"statement\":\(jsonString(entry.payload.statement))"
            if let temporal = entry.payload.temporal {
                fields += ",\"temporal\":\(jsonString(temporal.originalExpression))"
                fields += ",\"temporalKind\":\(jsonString(temporal.kind.rawValue))"
            }
            if let condition = entry.payload.applicability.conditionText {
                fields += ",\"condition\":\(jsonString(condition))"
            }
            if entry.needsQualifiedExpression {
                fields += ",\"needsQualifiedExpression\":true"
            }
            if let status = entry.currentOccurrenceStatus {
                fields += ",\"currentOccurrenceStatus\":\(jsonString(status.rawValue))"
            }
            contextLines.append("{" + fields + "}")
        }
        var segmentLines: [String] = []
        for segment in fallbackSegments {
            segmentLines.append(
                "{\"sourceID\":\(jsonString(segment.sourceID))," +
                "\"text\":\(jsonString(segment.text))}"
            )
        }
        let frameJSON = "{" +
            "\"utterance\":\(jsonString(frame.utterance))," +
            "\"goalSummary\":\(jsonString(frame.goalSummary))," +
            "\"successConditions\":\( jsonArray(frame.successConditions))," +
            "\"timeRange\":\(jsonString(frame.timeRangeExpression ?? ""))," +
            "\"unknowns\":\(jsonArray(frame.unknowns))," +
            "\"referenceTime\":\(jsonString(iso(frame.referenceTime)))" +
        "}"
        return "{" +
            "\"currentRequest\":\(frameJSON)," +
            "\"contexts\":[" + contextLines.joined(separator: ",") + "]," +
            "\"rawFallbackSegments\":[" + segmentLines.joined(separator: ",") + "]," +
            "\"semanticCoverage\":\(jsonString(semanticCoverage.rawValue))" +
        "}"
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode([value])) ?? Data("[]".utf8)
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }

    private static func jsonArray(_ values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - 内存持久化（standalone 测试用）

nonisolated actor HoloPlanningInMemoryRunPersistence: HoloPlanningRunPersisting {
    private var runs: [String: HoloPlanningRun] = [:]
    private var drafts: [String: HoloContextPlanDraft] = [:]

    func saveRun(_ run: HoloPlanningRun) async throws {
        runs[run.runID] = run
    }

    func loadRun(runID: String) async throws -> HoloPlanningRun? {
        runs[runID]
    }

    func saveDraft(_ draft: HoloContextPlanDraft) async throws {
        drafts[draft.runID] = draft
    }

    var latestDrafts: [String: HoloContextPlanDraft] { drafts }

    func runsSnapshot() -> [String: HoloPlanningRun] { runs }
}
