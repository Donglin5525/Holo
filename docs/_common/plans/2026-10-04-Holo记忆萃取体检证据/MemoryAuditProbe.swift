// 体检探针：使用真实的纯逻辑实现复现缺口，不改业务数据、不请求模型。
import Foundation
import CoreData

private final class AuditContextWriter: HoloPersonalContextRecordWriting, @unchecked Sendable {
    var records: [HoloMemoryRecord] = []
    var receipts = Set<String>()
    var cursor: HoloContextExtractionCursorState?
    func existingContextRecords() async throws -> [HoloMemoryRecord] { records }
    func write(records: [HoloMemoryRecord], batchKey: String) async throws {
        self.records.append(contentsOf: records)
        receipts.insert(batchKey)
    }
    func hasSuccessfulBatch(batchKey: String) async throws -> Bool { receipts.contains(batchKey) }
    func activeTombstones() async throws -> [HoloMemoryTombstone] { [] }
    func loadCursor() async throws -> HoloContextExtractionCursorState? { cursor }
    func saveCursor(_ cursor: HoloContextExtractionCursorState) async throws { self.cursor = cursor }
    func loadCursor(domain: String) async throws -> HoloContextExtractionCursorState? { cursor }
    func saveCursor(_ cursor: HoloContextExtractionCursorState, domain: String) async throws { self.cursor = cursor }
    func currentGeneration() async throws -> HoloContextExtractionGeneration {
        .init(userDecisionVersion: 1, learningBaselineAt: nil)
    }
    func currentSourceRevisions(sourceIDs: [String]) async throws -> [String: String] { [:] }
}

private final class AuditEmptyLLM: HoloPersonalContextLLMCalling, @unchecked Sendable {
    var extractionCalls = 0
    func extract(prompt: String) async throws -> String {
        extractionCalls += 1
        return "{\"candidates\":[],\"counterEvidence\":[]}"
    }
    func verify(prompt: String) async throws -> String { "{\"verdicts\":[]}" }
}

private actor AuditFeedbackStore: HoloMemoryFeedbackStore {
    var record: HoloMemoryRecord
    init(_ record: HoloMemoryRecord) { self.record = record }
    func fetch(id: String) async throws -> HoloMemoryRecord? { record }
    func query(_ query: HoloMemoryRepositoryQuery) async throws -> [HoloMemoryRecord] { [record] }
    func markUserDecision(id: String, decision: HoloMemoryUserDecision, now: Date) async throws -> Bool { true }
    func loadControlState() async throws -> HoloMemoryControlState { .initial(now: .distantPast) }
    func saveControlState(_ state: HoloMemoryControlState) async throws {}
    func saveTombstone(_ tombstone: HoloMemoryTombstone) async throws {}
    func replaceRecordForUserControl(_ record: HoloMemoryRecord) async throws { self.record = record }
    func deleteRecord(id: String) async throws -> Bool { true }
}

@main
private struct MemoryAuditProbe {
    static let now = Date(timeIntervalSince1970: 1_791_072_000)
    static func report(_ id: String, _ detail: String, reproduced: Bool) {
        print("\(id) | \(reproduced ? "REPRODUCED" : "NOT_REPRODUCED") | \(detail)")
    }

    static func main() async throws {
        // 统一采用当前 v4 默认规则，结束时恢复原值；此命令行进程不会修改 App 的偏好域。
        let key = "holo_memory_decisionPolicyV4Enabled"
        let old = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let old { UserDefaults.standard.set(old, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let anchor = try HoloMemoryAnchorRef(type: .financeCategory, value: "餐饮")
        let evidence = HoloMemoryEvidenceRef(
            id: "real-finance-evidence", kind: .aggregateSnapshot, sourceDomain: .finance,
            lineageKey: "finance-current-total", revisionDigest: "r1", observedAt: now,
            validFrom: now.addingTimeInterval(-90 * 86_400), validTo: now,
            aggregateDefinition: "90天餐饮支出，合计100元", sampleCount: 10
        )
        let signal = try HoloDomainSignalBuilder.make(
            id: "real-signal", domain: .finance, kind: .aggregate, evidence: evidence,
            anchors: [anchor], numericFacts: ["totalExpense": 100],
            prohibitedInferences: ["不得据此推断收入"]
        )
        let window = HoloMemoryObservationWindow.make(
            target: .domain(.finance), dirtySince: now, now: now, catchUpLimit: 14 * 86_400
        )
        let package = HoloDomainObservationPackageBuilder.build(domain: .finance, window: window, signals: [signal])
        let fabricated = HoloDomainMemoryCandidateOutput(
            domain: .finance, claimKind: .observedFact, persistenceClass: .currentState,
            displaySummary: "最近90天餐饮支出999999元", aiUseSummary: "最近90天餐饮支出999999元",
            anchors: [anchor], evidenceIDs: [evidence.id], prohibitedInferences: []
        )
        let result = HoloDomainMemoryOutputValidator.validate(
            envelope: .init(candidates: [fabricated]), against: package,
            now: now, extractorVersion: 1, promptVersion: 2
        )
        report("A01", "真实数字100，错误摘要999999：accepted=\(result.validRecords.count), state=\(result.validRecords.first?.state.rawValue ?? "nil")",
               reproduced: result.validRecords.first?.state == .active && result.rejections.isEmpty)
        report("A02", "输入禁止推断1项，输出约束=\(result.validRecords.first?.prohibitedInferences.count ?? -1)",
               reproduced: result.validRecords.first?.prohibitedInferences.isEmpty == true)
        report("A03", "90天证据被写成调度当天时间窗；sourceStart=\(evidence.validFrom?.timeIntervalSince1970 ?? 0), recordStart=\(result.validRecords.first?.validFrom?.timeIntervalSince1970 ?? 0)",
               reproduced: result.validRecords.first?.validFrom != evidence.validFrom)

        let inputs = ["我喜欢短回答", "我喜欢徒步"].enumerated().map { index, text in
            ConversationMemoryInput(id: "user-\(index)", role: .user, statementKind: .explicitPreference,
                text: text, revisionDigest: "r\(index)", createdAt: now, profileAnchor: nil)
        }
        let preferenceSignals = ConversationMemorySignalBuilder.build(from: inputs)
        let preferencePackage = HoloDomainObservationPackageBuilder.build(
            domain: .conversation, window: window, signals: preferenceSignals
        )
        let preferenceOutputs = preferenceSignals.map { item in
            HoloDomainMemoryCandidateOutput(
                domain: .conversation, claimKind: .explicitPreference, persistenceClass: .durable,
                displaySummary: item.userText ?? "", aiUseSummary: item.userText ?? "",
                anchors: item.anchors, evidenceIDs: [item.evidence.id], prohibitedInferences: []
            )
        }
        let preferences = HoloDomainMemoryOutputValidator.validate(
            envelope: .init(candidates: preferenceOutputs), against: preferencePackage,
            now: now, extractorVersion: 1, promptVersion: 2
        )
        report("A04", "2条不同偏好经真实Validator后剩\(preferences.validRecords.count)条",
               reproduced: preferenceOutputs.count == 2 && preferences.validRecords.count == 1)
        if let record = preferences.validRecords.first {
            let later = window.end.addingTimeInterval(1)
            let decision = HoloMemoryDecisionPolicy.evaluate(record, now: later)
            let recalled = HoloMemoryRecallPolicy.isEligible(record, now: later)
            report("A05", "次日重新裁决=\(decision.route)，真实召回允许=\(recalled)",
                   reproduced: decision.route == .discard && recalled)
        }

        let source = HoloContextSourceSnapshot(
            sourceID: "task:1", sourceDomain: "task", sourceKind: "todoTask", revisionDigest: "r1",
            sourceCreatedAt: now, sourceUpdatedAt: now, plainText: "任务「买猫粮」",
            sensitivity: .normal, accessGeneration: 1, authorship: "quoted",
            lineageRootIDs: ["evt-1"], businessState: ["completed": "false"]
        )
        let prompt = HoloPersonalContextPromptBuilder.extractionPrompt(
            packageSegments: HoloContextSegmenter.segments(for: source),
            sourcesByID: [source.sourceID: source], existingCandidates: []
        )
        let discardedFields = ["businessState", "completed", "sourceDomain", "sourceKind", "authorship", "lineageRootIDs"]
        report("A06", "运行时已有业务状态/归属/血缘，但生成Prompt丢失字段=\(discardedFields.filter { !prompt.contains($0) }.joined(separator: ","))",
               reproduced: discardedFields.allSatisfy { !prompt.contains($0) })

        let candidate = HoloContextExtractionCandidateDTO(
            candidateRef: "c1", statement: "用户喜欢短回答", subjects: [.init(label: "我", scope: .user)],
            facets: [.init(kind: .preference)], epistemicStatus: "observed",
            basis: [.init(sourceID: source.sourceID)], openQuestions: []
        )
        let validation = HoloPersonalContextValidator.validate(
            response: .init(candidates: [candidate], counterEvidence: []), packageSources: [source]
        )
        report("A07", "quote和revision均缺失，结构校验仍接受\(validation.valid.count)条",
               reproduced: validation.valid.count == 1)

        // 单一长来源跨两个包，当前批次键只包含来源修订，第二包被当作重复。
        let longSource = HoloContextSourceSnapshot(
            sourceID: "long-note", sourceDomain: "thought", sourceKind: "userNote", revisionDigest: "r1",
            sourceCreatedAt: now, sourceUpdatedAt: now, plainText: String(repeating: "长", count: 18_000),
            sensitivity: .normal, accessGeneration: 1
        )
        var remaining = HoloContextSegmenter.segments(for: longSource)
        var expectedPackages = 0
        while !remaining.isEmpty {
            let (pack, rest) = HoloContextSegmenter.packageSegments(remaining)
            guard !pack.isEmpty else { break }
            expectedPackages += 1
            remaining = rest
        }
        let llm = AuditEmptyLLM()
        let writer = AuditContextWriter()
        let extractor = HoloPersonalContextExtractor(
            paging: HoloContextInMemorySourcePaging(sources: [longSource]), llm: llm, writer: writer
        )
        _ = try await extractor.runOneBatch(now: now)
        report("A08", "18000字单条想法应处理\(expectedPackages)包，实际萃取调用\(llm.extractionCalls)次",
               reproduced: expectedPackages > llm.extractionCalls)

        let personalSource = HoloContextSourceSnapshot(
            sourceID: "thought-pref", sourceDomain: "thought", sourceKind: "userNote", revisionDigest: "r1",
            sourceCreatedAt: now, sourceUpdatedAt: now, plainText: "我喜欢短回答",
            sensitivity: .normal, accessGeneration: 1
        )
        let declared = HoloContextExtractionCandidateDTO(
            candidateRef: "pref", statement: "用户喜欢短回答", subjects: [.init(label: "我", scope: .user)],
            facets: [.init(kind: .preference)], epistemicStatus: "declared",
            basis: [.init(sourceID: personalSource.sourceID, quote: "我喜欢短回答", revision: "r1")]
        )
        let decisions = HoloContextReconciler.reconcile(
            candidates: [declared], verdicts: [.init(candidateRef: "pref", verdict: .qualified,
                requiredQualifiers: ["仅本次交流"], reason: "需要缩窄范围")],
            existingRecords: [], packageSources: [personalSource], now: now
        )
        if let payload = decisions.first?.payload,
           let record = HoloPersonalContextExtractor.newRecord(payload: payload, claimKind: .explicitPreference,
               sensitivity: .normal, packageSources: [personalSource], now: now) {
            report("A09", "语义核验qualified，落库用途=\(record.decisionMetadata?.v2?.useLevel.rawValue ?? "nil")",
                   reproduced: record.decisionMetadata?.v2?.useLevel == .factEligible)
            let feedbackStore = AuditFeedbackStore(record)
            let corrected = try await HoloMemoryFeedbackService(store: feedbackStore).correct(
                id: record.id, summary: "用户需要详细解释", now: now.addingTimeInterval(10)
            )
            let advice = HoloContextAccessPolicy.selectAdviceCandidates(records: [corrected])
            report("A10", "真实纠正后summary=\(corrected.aiUseSummary)，payload=\(corrected.personalContext?.v1?.statement ?? "nil")，规划可用=\(advice.selected.count)",
                   reproduced: corrected.personalContext?.v1?.statement != corrected.aiUseSummary && advice.selected.isEmpty)
        }

        try paginationProbe()
        let attributed = HoloMemoryAttributionReconciler.matchedMemoryIDs(
            reply: "你刚才提到预算，我按这次输入来解释预算。",
            entries: [.init(id: "unused-budget", text: "财务记忆：每月的预算是2000元")]
        )
        report("A12", "只有通用词预算重合，也署名为使用记忆=\(attributed)", reproduced: !attributed.isEmpty)
    }

    // Core Data缩小复现：移植财务/任务适配器的查询、截断、游标过滤顺序；不启动App仓库。
    static func paginationProbe() throws {
        let entity = NSEntityDescription()
        entity.name = "AuditRow"
        entity.managedObjectClassName = "NSManagedObject"
        let id = NSAttributeDescription()
        id.name = "id"; id.attributeType = .stringAttributeType
        let timestamp = NSAttributeDescription()
        timestamp.name = "updatedAt"; timestamp.attributeType = .dateAttributeType
        entity.properties = [id, timestamp]
        let model = NSManagedObjectModel(); model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        for index in 1...151 {
            let item = NSEntityDescription.insertNewObject(forEntityName: "AuditRow", into: context)
            item.setValue(String(format: "%03d", index), forKey: "id")
            item.setValue(now.addingTimeInterval(Double(index)), forKey: "updatedAt")
        }
        try context.save()
        var cursor: (Date, String)?
        var counts: [Int] = []
        var reached = Set<String>()
        for _ in 0..<4 {
            let request = NSFetchRequest<NSManagedObject>(entityName: "AuditRow")
            request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: true), NSSortDescriptor(key: "id", ascending: true)]
            request.fetchLimit = cursor == nil ? 50 : 100
            let results = try context.fetch(request)
            let filtered = results.drop { item in
                guard let cursor, let time = item.value(forKey: "updatedAt") as? Date,
                      let key = item.value(forKey: "id") as? String else { return false }
                return time < cursor.0 || (time == cursor.0 && key <= cursor.1)
            }
            let page = Array(filtered.prefix(50))
            counts.append(page.count)
            reached.formUnion(page.compactMap { $0.value(forKey: "id") as? String })
            if let last = page.last, let time = last.value(forKey: "updatedAt") as? Date,
               let key = last.value(forKey: "id") as? String { cursor = (time, key) }
            else { cursor = nil }
        }
        report("A11", "151行真实CoreData，4轮页大小=\(counts)，仅到达\(reached.count)行",
               reproduced: counts == [50, 50, 0, 50] && reached.count == 100)
    }
}
