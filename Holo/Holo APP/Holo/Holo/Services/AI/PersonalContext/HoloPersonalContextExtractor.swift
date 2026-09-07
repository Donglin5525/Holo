//
//  HoloPersonalContextExtractor.swift
//  Holo
//
//  通用个人情境萃取编排器（实施方案 §6）。
//
//  流程：稳定分页 → 权限/基线检查 → 切段组包 → LLM 萃取 → 结构校验 →
//        LLM 批量核验 → 归并（含墓碑 suppression）→ 记录落库+批次 receipt →
//        游标推进（先落库再推）。
//  竞态纪律：LLM 返回后复查用户控制代际与源修订；变化即拒绝过期批次、不推进游标、
//  重新排队。批处理以 source revision + extractorVersion + policyVersion + batchKey 幂等，
//  重复请求复用已保存结果。
//  依赖全部协议注入（clock/store/llm/paging），Core Data 与 Provider 接线在调用方实现。
//

import Foundation

// MARK: - 依赖协议

/// 编排器需要的 LLM 调用（窄协议，测试与接线各自实现）。
nonisolated protocol HoloPersonalContextLLMCalling: Sendable {
    func extract(prompt: String) async throws -> String
    func verify(prompt: String) async throws -> String
}

/// 落库与状态存取（Core Data 适配器在接线层实现）。
nonisolated protocol HoloPersonalContextRecordWriting: Sendable {
    /// 输入包涉及的既有情境记录（供归并匹配）。
    func existingContextRecords() async throws -> [HoloMemoryRecord]
    /// 原子写入：记录与批次 receipt 同事务；已存在成功 receipt 时为幂等空操作。
    func write(records: [HoloMemoryRecord], batchKey: String) async throws
    func hasSuccessfulBatch(batchKey: String) async throws -> Bool
    /// 活动墓碑（suppression 检查）。
    func activeTombstones() async throws -> [HoloMemoryTombstone]
    func loadCursor() async throws -> HoloContextExtractionCursorState?
    func saveCursor(_ cursor: HoloContextExtractionCursorState) async throws
    /// 当前控制代际（用户决策版本 + 学习基线）；每批前后复查。
    func currentGeneration() async throws -> HoloContextExtractionGeneration
    /// 来源当前修订目录（对账用：sourceID → 当前修订）。
    func currentSourceRevisions(sourceIDs: [String]) async throws -> [String: String]
}

/// 控制代际快照。
nonisolated struct HoloContextExtractionGeneration: Equatable, Sendable {
    var userDecisionVersion: Int64
    var learningBaselineAt: Date?
}

/// 萃取进度（内部进度：总扫描量、已处理修订、待处理、失败与索引覆盖）。
nonisolated struct HoloContextExtractionProgress: Codable, Equatable, Sendable {
    var scannedSources = 0
    var processedRevisions = 0
    var pendingBatches = 0
    var failedBatches = 0
    var suppressedCandidates = 0
    var discardedCandidates = 0
    var mergedCandidates = 0
    var createdRecords = 0
}

// MARK: - 游标状态

/// 萃取游标：受保护的本地状态；含批次 watermark 与进度。
nonisolated struct HoloContextExtractionCursorState: Codable, Equatable, Sendable {
    var sourceCursor: HoloContextSourceCursor?
    var progress: HoloContextExtractionProgress
    /// 上次批次的水位时间：批次期间新修改进入下一批。
    var watermark: Date?
    var extractorVersion: Int
    var admissionPolicyVersion: Int

    init(
        sourceCursor: HoloContextSourceCursor? = nil,
        progress: HoloContextExtractionProgress = HoloContextExtractionProgress(),
        watermark: Date? = nil,
        extractorVersion: Int = 1,
        admissionPolicyVersion: Int = HoloContextReconciler.admissionPolicyVersion
    ) {
        self.sourceCursor = sourceCursor
        self.progress = progress
        self.watermark = watermark
        self.extractorVersion = extractorVersion
        self.admissionPolicyVersion = admissionPolicyVersion
    }
}

// MARK: - Prompt 组装

nonisolated enum HoloPersonalContextPromptBuilder {
    /// 萃取输入包 prompt：来源片段（含 role/时间）、供合并的既有候选。
    static func extractionPrompt(
        packageSegments: [HoloContextSegment],
        sourcesByID: [String: HoloContextSourceSnapshot],
        existingCandidates: [HoloPersonalContextPayloadV1]
    ) -> String {
        var lines: [String] = []
        for segment in packageSegments {
            let source = sourcesByID[segment.sourceID]
            var fields = "\"sourceID\":\(jsonString(segment.sourceID))"
            fields += ",\"revision\":\(jsonString(segment.revision))"
            if let role = source?.role { fields += ",\"role\":\(jsonString(role))" }
            if let recorded = source?.sourceCreatedAt {
                fields += ",\"recordedAt\":\(jsonString(iso(recorded)))"
            }
            if let event = source?.eventTime {
                fields += ",\"eventTime\":\(jsonString(iso(event)))"
            }
            fields += ",\"plainText\":\(jsonString(segment.text))"
            lines.append("{" + fields + "}")
        }
        let existing = existingCandidates.map { payload in
            "{\"contextID\":\(jsonString(payload.contextID)),\"statement\":\(jsonString(payload.statement))}"
        }
        let sourcesJSON = lines.joined(separator: ",")
        let existingJSON = existing.joined(separator: ",")
        return "{\"sources\":[" + sourcesJSON + "],\"existingCandidates\":[" + existingJSON + "]}"
    }

    /// 核验 prompt：候选声明 + 引用原文片段；批量（每包候选上限 16）。
    static func verificationPrompt(
        candidates: [HoloContextExtractionCandidateDTO],
        sourcesByID: [String: HoloContextSourceSnapshot]
    ) -> String {
        var lines: [String] = []
        for candidate in candidates {
            var fields = "\"candidateRef\":\(jsonString(candidate.candidateRef))"
            fields += ",\"statement\":\(jsonString(candidate.statement))"
            if let epistemic = candidate.epistemicStatus {
                fields += ",\"epistemicStatus\":\(jsonString(epistemic))"
            }
            if let temporal = candidate.temporal {
                fields += ",\"temporal\":\(jsonString(temporal.originalExpression))"
            }
            let quotes = candidate.basis.compactMap { basis -> String? in
                guard let quote = basis.quote else { return nil }
                return "{\"sourceID\":" + jsonString(basis.sourceID) + ",\"quote\":" + jsonString(quote) + "}"
            }
            let quotesJSON = quotes.joined(separator: ",")
            fields += ",\"basis\":[" + quotesJSON + "]"
            lines.append("{" + fields + "}")
        }
        var sourceLines: [String] = []
        for (id, source) in sourcesByID.sorted(by: { $0.key < $1.key }) {
            sourceLines.append("{\"sourceID\":" + jsonString(id) + ",\"plainText\":" + jsonString(source.plainText) + "}")
        }
        let candidatesJSON = lines.joined(separator: ",")
        let sourcesJSON = sourceLines.joined(separator: ",")
        return "{\"candidates\":[" + candidatesJSON + "],\"sources\":[" + sourcesJSON + "]}"
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode([value])) ?? Data("[]".utf8)
        // [String] 编码取掉首尾方括号，得到带转义的单字符串字面量。
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}

// MARK: - 编排器

/// 萃取诊断日志钩子（DEBUG 调试用；生产置 nil 零开销）。
nonisolated enum ExtractionDebugLog {
    nonisolated(unsafe) static var error: (any ErrorLogger)? = SystemLogger()

    nonisolated protocol ErrorLogger: Sendable {
        func log(_ message: String)
    }

    struct SystemLogger: ErrorLogger {
        func log(_ message: String) {
            #if DEBUG
            print("[EXTRACT-DIAG] \(message)")
            NSLog("EXTRACT-DIAG %@", message)
            #endif
        }
    }
}

nonisolated struct HoloPersonalContextExtractor: Sendable {
    /// 每包候选上限（方案 §6 初始预算）。
    static let candidatesPerPackageLimit = 16
    /// 页大小（方案 §6 初始预算：源分页 50）。
    static let pageSize = 50

    let paging: any HoloContextSourcePaging
    let llm: any HoloPersonalContextLLMCalling
    let writer: any HoloPersonalContextRecordWriting

    init(
        paging: any HoloContextSourcePaging,
        llm: any HoloPersonalContextLLMCalling,
        writer: any HoloPersonalContextRecordWriting
    ) {
        self.paging = paging
        self.llm = llm
        self.writer = writer
    }

    enum ExtractionError: Error, Equatable {
        /// 用户控制代际变化：丢弃本批结果，重新排队（不推进游标）。
        case generationChanged
        /// 源修订在 LLM 返回前变化：拒绝过期批次，重新排队。
        case sourceRevisionChanged(sourceID: String)
        /// 页读取后源被修改（对账不通过）。
        case stalePackage
    }

    struct BatchOutcome: Equatable, Sendable {
        var createdRecords = 0
        var mergedRecords = 0
        var suppressed = 0
        var discarded = 0
        var hasMore = false
    }

    /// 跑一批。成功时记录+receipt 原子落库后推进游标；失败时不推进（下次重试）。
    /// - Parameter now: 注入时钟。
    func runOneBatch(now: Date) async throws -> BatchOutcome {
        var cursor = try await writer.loadCursor() ?? HoloContextExtractionCursorState()
        let generationAtStart = try await writer.currentGeneration()

        // 组包：一页来源 → 全部切段 → 取一个包。
        let (page, nextCursor) = try await paging.fetchContextSourcePage(
            after: cursor.sourceCursor,
            limit: Self.pageSize,
            baseline: generationAtStart.learningBaselineAt
        )
        guard !page.isEmpty else {
            // 全量追平：清游标从头对账（新修改由 watermark 语义进入下一轮）。
            if nextCursor == nil && cursor.sourceCursor != nil {
                cursor.sourceCursor = nil
                cursor.watermark = now
                try await writer.saveCursor(cursor)
            }
            return BatchOutcome()
        }

        let packageBatchKey = Self.batchKey(
            sources: page,
            extractorVersion: cursor.extractorVersion,
            policyVersion: cursor.admissionPolicyVersion
        )

        // 幂等：重复请求复用已保存结果，不再调 LLM。
        if try await writer.hasSuccessfulBatch(batchKey: packageBatchKey) {
            cursor.sourceCursor = nextCursor
            cursor.progress.processedRevisions += page.count
            try await writer.saveCursor(cursor)
            return BatchOutcome(hasMore: nextCursor != nil)
        }

        // 切段组包（一个包；剩余段留给下一批——同页多包由调用方循环）。
        var allSegments: [HoloContextSegment] = []
        var sourcesByID: [String: HoloContextSourceSnapshot] = [:]
        for source in page {
            sourcesByID[source.sourceID] = source
            allSegments.append(contentsOf: HoloContextSegmenter.segments(for: source))
        }
        let (package, _) = HoloContextSegmenter.packageSegments(allSegments)
        guard !package.isEmpty else {
            cursor.sourceCursor = nextCursor
            try await writer.saveCursor(cursor)
            return BatchOutcome(hasMore: nextCursor != nil)
        }

        // 萃取调用。
        let existingRecords = try await writer.existingContextRecords()
        let existingCandidates = existingRecords.compactMap(\.personalContext?.v1)
        let extractionRaw = try await llm.extract(
            prompt: HoloPersonalContextPromptBuilder.extractionPrompt(
                packageSegments: package,
                sourcesByID: sourcesByID,
                existingCandidates: existingCandidates
            )
        )
        let response = try HoloPersonalContextResponseParser.parseExtraction(extractionRaw)

        // 结构校验。
        let (validCandidates, findings) = HoloPersonalContextValidator.validate(
            response: response,
            packageSources: page
        )
        // DEBUG 诊断（仅本地调试构建；不含用户原文，只含数量与候选 ref）
        #if DEBUG
        ExtractionDebugLog.error?.log("EXTRACT-DIAG rawLen=\(extractionRaw.count) candidates=\(response.candidates.count) valid=\(validCandidates.count) findings=\(findings.map { "\($0.candidateRef):\($0.code.rawValue)" }.joined(separator: ","))")
        ExtractionDebugLog.error?.log("EXTRACT-DIAG RAW: \(extractionRaw.prefix(1200))")
        #endif
        guard !validCandidates.isEmpty else {
            // 无候选：本包完成，receipt 空批也落（避免重复 LLM）。
            try await writer.write(records: [], batchKey: packageBatchKey)
            cursor.sourceCursor = nextCursor
            cursor.progress.processedRevisions += page.count
            try await writer.saveCursor(cursor)
            return BatchOutcome(hasMore: nextCursor != nil)
        }

        // 语义核验（批量，候选上限保护——超出部分按缺 verdict 处理进待确认）。
        let toVerify = Array(validCandidates.prefix(Self.candidatesPerPackageLimit))
        let verifyRaw = try await llm.verify(
            prompt: HoloPersonalContextPromptBuilder.verificationPrompt(
                candidates: toVerify,
                sourcesByID: sourcesByID
            )
        )
        let verdicts = try HoloContextVerificationParser.parse(verifyRaw)

        // 归并。
        var decisions = HoloContextReconciler.reconcile(
            candidates: validCandidates,
            verdicts: verdicts,
            existingRecords: existingRecords,
            packageSources: page,
            now: now
        )

        // 墓碑 suppression：换 contextID 重生拦截。
        let tombstones = try await writer.activeTombstones()
        var suppressed = 0
        var kept: [HoloContextReconcileDecision] = []
        for decision in decisions {
            if let payload = decision.payload,
               tombstones.contains(where: { tombstone in
                   HoloSemanticTombstoneMatcher.contextSuppressionMatches(tombstone: tombstone, payload: payload)
               }) {
                suppressed += 1
                continue
            }
            kept.append(decision)
        }
        decisions = kept

        // 竞态复查①：用户控制代际变化 → 拒绝过期批次。
        let generationNow = try await writer.currentGeneration()
        guard generationNow == generationAtStart else {
            throw ExtractionError.generationChanged
        }
        // 竞态复查②：来源修订变化 → 拒绝过期批次，重新排队。
        let revisionsNow = try await writer.currentSourceRevisions(
            sourceIDs: page.map(\.sourceID)
        )
        for source in page {
            if let current = revisionsNow[source.sourceID], current != source.revisionDigest {
                throw ExtractionError.sourceRevisionChanged(sourceID: source.sourceID)
            }
        }

        // 记录构造 + 落库（先落库再推游标）。
        var records: [HoloMemoryRecord] = []
        var outcome = BatchOutcome()
        for decision in decisions {
            switch decision.action {
            case .discard:
                outcome.discarded += 1
            case .mergeIntoExisting:
                outcome.mergedRecords += 1
                // 合并的记录更新由 writer 应用（附加证据、复用 contextID）。
                if let payload = decision.payload,
                   let target = existingRecords.first(where: { $0.id == decision.targetRecordID }) {
                    records.append(Self.mergedRecord(from: target, appending: payload, now: now))
                }
            case .create:
                guard let payload = decision.payload,
                      let claimKind = decision.claimKind,
                      let record = Self.newRecord(
                        payload: payload,
                        claimKind: claimKind,
                        sensitivity: decision.sensitivity,
                        packageSources: page,
                        now: now
                      ) else { continue }
                records.append(record)
                outcome.createdRecords += 1
            }
        }
        try await writer.write(records: records, batchKey: packageBatchKey)

        // 游标推进（成功落库后）。
        cursor.sourceCursor = nextCursor
        cursor.progress.scannedSources += page.count
        cursor.progress.processedRevisions += page.count
        cursor.progress.suppressedCandidates += suppressed
        cursor.progress.discardedCandidates += outcome.discarded
        cursor.progress.mergedCandidates += outcome.mergedRecords
        cursor.progress.createdRecords += outcome.createdRecords
        cursor.watermark = now
        try await writer.saveCursor(cursor)

        outcome.suppressed = suppressed
        outcome.hasMore = nextCursor != nil
        return outcome
    }

    // MARK: - 记录构造

    /// 稳定批次键：source revision + extractorVersion + policyVersion。
    static func batchKey(
        sources: [HoloContextSourceSnapshot],
        extractorVersion: Int,
        policyVersion: Int
    ) -> String {
        let identity = sources
            .sorted { $0.sourceID < $1.sourceID }
            .map { "\($0.sourceID)@\($0.revisionDigest)" }
            .joined(separator: ",")
        return "pc-batch-\(HoloContextSuppressionKeys.stableDigest("v\(extractorVersion)|p\(policyVersion)|\(identity)"))"
    }

    /// String → 既有记忆域（快照域是开放字符串；未知回落 thought）。
    static func memoryDomain(_ raw: String) -> HoloMemoryDomain {
        HoloMemoryDomain(rawValue: raw) ?? .thought
    }

    /// 从决策构造新记录：candidate 默认、锚点用 contextID、稳定 ID 沿用既有算法。
    static func newRecord(
        payload: HoloPersonalContextPayloadV1,
        claimKind: HoloMemoryClaimKind,
        sensitivity: HoloMemorySensitivity,
        packageSources: [HoloContextSourceSnapshot],
        now: Date
    ) -> HoloMemoryRecord? {
        guard let anchor = try? HoloMemoryAnchorRef(
            type: .userTheme,
            value: payload.contextAnchorValue
        ) else { return nil }
        let domain = packageSources.first.flatMap {
            $0.sourceID == payload.basis.first?.sourceID ? Self.memoryDomain($0.sourceDomain) : nil
        } ?? .thought
        guard let stableID = try? HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            claimKind: claimKind,
            anchors: [anchor]
        ) else { return nil }
        let evidence = payload.basis.map { basis in
            HoloMemoryEvidenceRef(
                id: "ctx-\(HoloContextSuppressionKeys.stableDigest("\(payload.contextID)|\(basis.sourceID)|\(basis.quote ?? "")"))",
                kind: .explicitUserStatement,
                sourceDomain: domain,
                lineageKey: basis.sourceID,
                sourceID: basis.sourceID,
                revisionDigest: basis.sourceRevision,
                observedAt: now
            )
        }
        return HoloMemoryRecord(
            id: stableID,
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            subjectKey: "个人情境",
            anchorRefs: [anchor],
            claimKind: claimKind,
            persistenceClass: .durable,
            displaySummary: payload.statement,
            aiUseSummary: payload.statement,
            prohibitedInferences: [],
            evidenceRefs: evidence,
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            confidenceScore: 0.5,
            freshnessScore: 0.5,
            scoringVersion: 1,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .candidate,
            sensitivity: sensitivity,
            userDecision: .none,
            createdAt: now,
            updatedAt: now,
            personalContext: HoloPersonalContextPayloadEnvelope(v1: payload)
        )
    }

    /// 合并既有记录：复用稳定 ID 与 contextID，追加证据、推进版本。
    static func mergedRecord(
        from target: HoloMemoryRecord,
        appending payload: HoloPersonalContextPayloadV1,
        now: Date
    ) -> HoloMemoryRecord {
        var record = target
        var mergedPayload = payload
        // 复用目标身份：contextID 不变 → 锚点/稳定 ID 不变。
        if let existing = record.personalContext?.v1 {
            let mergedBasis = existing.basis + payload.basis.filter { basis in
                !existing.basis.contains { $0.sourceID == basis.sourceID && $0.quote == basis.quote }
            }
            mergedPayload = HoloPersonalContextPayloadV1(
                contextID: existing.contextID,
                statement: existing.statement,
                subjects: existing.subjects,
                objects: existing.objects,
                relationText: existing.relationText,
                facets: existing.facets,
                epistemicStatus: existing.epistemicStatus,
                applicability: existing.applicability,
                temporal: existing.temporal,
                basis: mergedBasis,
                linkedContextIDs: Array(Set(existing.linkedContextIDs + payload.linkedContextIDs)),
                openQuestions: existing.openQuestions,
                admission: payload.admission
            )
        }
        record.personalContext = HoloPersonalContextPayloadEnvelope(v1: mergedPayload)
        record.recordVersion += 1
        record.updatedAt = now
        return record
    }
}

extension HoloContextReconcileDecision {
    /// mergeIntoExisting 动作的记录 ID 便捷访问。
    var targetRecordID: String? {
        if case .mergeIntoExisting(let recordID) = action {
            return recordID
        }
        return nil
    }
}
