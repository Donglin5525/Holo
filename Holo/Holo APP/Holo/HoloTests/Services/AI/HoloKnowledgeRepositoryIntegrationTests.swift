import CoreData
import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloKnowledgeRepositoryIntegrationTests.main()
    }
}
#endif

/// 统一记忆仓库内的通用知识层：同事务落修订、双分区、query(.active) 统一门闸、
/// 控制事务、迁移幂等、逐行隔离、来源失效与复核（场景矩阵 M/C/S 子集）。
struct HoloKnowledgeRepositoryIntegrationTests {
    private static var assertionCount = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertionCount += 1
        if !condition() { fatalError("[HoloKnowledgeRepository] \(message)") }
    }

    private static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private static func day(_ n: Int) -> Date { t0.addingTimeInterval(TimeInterval(n) * 86_400) }

    private static func makeRecord(
        anchor: String,
        claimKind: HoloMemoryClaimKind,
        domain: HoloMemoryDomain = .habit,
        evidence: [HoloMemoryEvidenceRef],
        state: HoloMemoryState = .active,
        userDecision: HoloMemoryUserDecision = .none,
        summary: String? = nil,
        updatedAt: Date = t0
    ) throws -> HoloMemoryRecord {
        let anchorRef = try HoloMemoryAnchorRef(type: .userTheme, value: anchor)
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain, primaryDomain: domain, sourceDomains: [domain],
            claimKind: claimKind, anchors: [anchorRef]
        )
        return HoloMemoryRecord(
            id: id, scope: .domain, primaryDomain: domain, sourceDomains: [domain],
            subjectKey: anchor, anchorRefs: [anchorRef], claimKind: claimKind,
            persistenceClass: .durable,
            displaySummary: summary ?? "\(anchor) 的结论",
            aiUseSummary: summary ?? "\(anchor) 的结论",
            prohibitedInferences: [],
            evidenceRefs: evidence, upstreamMemoryIDs: [], counterEvidenceRefs: [],
            lastSupportedAt: updatedAt, confidenceScore: 0.8, freshnessScore: 1,
            scoringVersion: HoloMemoryScorer.currentVersion, scoreComputedAt: updatedAt,
            extractorVersion: 1, promptVersion: 1, state: state,
            sensitivity: domain == .health ? .sensitive : .normal,
            userDecision: userDecision, createdAt: updatedAt, updatedAt: updatedAt
        )
    }

    private static func statement(_ key: String, at: Date = t0) -> HoloMemoryEvidenceRef {
        HoloMemoryEvidenceRef(
            id: "s-\(key)", kind: .explicitUserStatement, sourceDomain: .conversation,
            lineageKey: "conversation:user:\(key)", sourceID: key, revisionDigest: "r-\(key)", observedAt: at
        )
    }

    private static func event(_ key: String, domain: HoloMemoryDomain = .habit, at: Date) -> HoloMemoryEvidenceRef {
        HoloMemoryEvidenceRef(
            id: "e-\(key)", kind: .entityRef, sourceDomain: domain,
            lineageKey: "\(domain.rawValue):\(key)", sourceID: UUID().uuidString,
            revisionDigest: "r-\(key)", observedAt: at
        )
    }

    private static func makeRepository() throws -> (CoreDataHoloMemoryRepository, HoloMemoryPersistenceController) {
        let controller = try HoloMemoryPersistenceController(inMemory: true)
        return (CoreDataHoloMemoryRepository(controller: controller), controller)
    }

    static func main() async throws {
        try await testIngestionWritesRevisionInSameTransaction()
        try await testActiveGateExcludesUnconfirmedInference()
        try await testHealthPartitionIsolation()
        try await testEvidenceRefreshDedupe()
        try await testControlServiceConfirmAndMirror()
        try await testControlServiceConflictAndForget()
        try await testMigrationIdempotentAndControlFirst()
        try await testRowLevelIsolation()
        try await testSourceInvalidationAndReconcile()
        try await testDiscoveryOriginRevisionWithoutAlias()
        print("HoloKnowledgeRepositoryIntegrationTests passed (\(assertionCount) assertions)")
    }

    // MARK: S31 / W2 统一写入

    static func testIngestionWritesRevisionInSameTransaction() async throws {
        let (repository, _) = try makeRepository()
        let record = try makeRecord(anchor: "short-answer", claimKind: .explicitPreference, domain: .conversation,
                                    evidence: [statement("a")], summary: "喜欢简短回答")
        let result = try await repository.upsert(record, observationKey: "obs-1")
        expect(result == .inserted, "旧记录照常写入")
        let snapshot = try await repository.knowledgeStoreSnapshot()
        expect(snapshot.revisions.count == 1, "同事务落一条知识修订")
        expect(snapshot.revisions.first?.sourceAliases == [record.id], "修订携带旧 ID 别名")
        expect(snapshot.revisions.first?.partition == .normal, "普通分区")
        expect(snapshot.revisions.first?.semantic.formation == .directExpression, "用户陈述 = 直接表达")
        let resolved = try await repository.resolvedKnowledge(propositionID: snapshot.revisions.first!.propositionID, now: day(1))
        expect(resolved?.decision == .remembered, "直接陈述直接记住")
        let active = try await repository.query(.active)
        expect(active.map(\.id) == [record.id], "query(.active) 经统一决策放行")
    }

    // MARK: M02 / C08 旧 active 自动碎片不再被使用

    static func testActiveGateExcludesUnconfirmedInference() async throws {
        let (repository, _) = try makeRepository()
        // 单一 lineage 的「规律」：state 为 active（旧端会直接用），但未成熟。
        let fragment = try makeRecord(anchor: "run", claimKind: .recurringPattern,
                                      evidence: [event("r1", at: day(0))], summary: "周末跑步")
        _ = try await repository.upsert(fragment, observationKey: "obs-f")
        let snapshot = try await repository.knowledgeStoreSnapshot()
        expect(snapshot.revisions.isEmpty, "证据不足的行为归纳停留后台，不建知识修订")
        let all = try await repository.query(.all)
        expect(all.map(\.id) == [fragment.id], "原记录保留（业务事实不动）")
        let active = try await repository.query(.active)
        expect(active.isEmpty, "M02/C08：未确认行为推断不再通过 active 旁路被消费")

        // 用户在旧界面确认过的记录：未迁移时按 §7.2 受限投影放行
        let confirmedLegacy = try makeRecord(anchor: "walk", claimKind: .recurringPattern,
                                             evidence: [event("w1", at: day(0))], userDecision: .confirmed, summary: "晚饭后散步")
        try await repository.replaceRecordForUserControl(confirmedLegacy)
        let active2 = try await repository.query(.active)
        expect(active2.map(\.id).contains(confirmedLegacy.id), "用户确认过的旧记录在迁移前仍可用（受限投影）")
        expect(!active2.map(\.id).contains(fragment.id), "自动碎片依旧不可用")
    }

    // MARK: S14 / M13 健康证据派生留本机分区

    static func testHealthPartitionIsolation() async throws {
        let (repository, controller) = try makeRepository()
        let health = try makeRecord(anchor: "sleep-limit", claimKind: .lifeEvent, domain: .health,
                                    evidence: [HoloMemoryEvidenceRef(id: "h1", kind: .explicitUserStatement, sourceDomain: .conversation,
                                                                     lineageKey: "health:aggregate:sleep", revisionDigest: "r", observedAt: t0)],
                                    summary: "未来两周不宜跑步")
        _ = try await repository.upsert(health, observationKey: "obs-h")
        let snapshot = try await repository.knowledgeStoreSnapshot()
        expect(snapshot.revisions.count == 1 && snapshot.revisions.first?.partition == .sensitiveLocal, "健康派生知识归本机分区")
        let mainContext = controller.mainContainer.newBackgroundContext()
        let mainCount = try await mainContext.perform {
            try mainContext.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "HoloMemoryKnowledgeRevisionMO"))
        }
        expect(mainCount == 0, "主库（同步）里没有敏感修订")
        let sensitiveContext = controller.sensitiveContainer.newBackgroundContext()
        let sensitiveCount = try await sensitiveContext.perform {
            try sensitiveContext.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "HoloMemoryKnowledgeRevisionMO"))
        }
        expect(sensitiveCount == 1, "敏感库里有且只有一条")
    }

    // MARK: C02 同语义证据刷新：不增新记忆、不反复确认

    static func testEvidenceRefreshDedupe() async throws {
        let (repository, _) = try makeRepository()
        let base = try makeRecord(anchor: "coffee", claimKind: .explicitPreference, domain: .conversation,
                                  evidence: [statement("c1")], summary: "喜欢咖啡")
        _ = try await repository.upsert(base, observationKey: "o1")
        _ = try await repository.upsert(base, observationKey: "o2")
        var snapshot = try await repository.knowledgeStoreSnapshot()
        expect(snapshot.revisions.count == 1, "重复写入同语义不增修订")
        expect(snapshot.operations.filter { $0.kind == .evidenceSnapshot }.isEmpty, "证据未变不写快照操作")

        var more = base
        more.evidenceRefs = [statement("c1"), statement("c2", at: day(1))]
        more.updatedAt = day(1)
        _ = try await repository.upsert(more, observationKey: "o3")
        snapshot = try await repository.knowledgeStoreSnapshot()
        expect(snapshot.revisions.count == 1, "新证据同语义仍是一条修订")
        expect(snapshot.operations.filter { $0.kind == .evidenceSnapshot }.count == 1, "新证据只刷新快照")
        let resolved = try await repository.resolvedKnowledge(propositionID: snapshot.revisions.first!.propositionID, now: day(2))
        expect(resolved?.latestEvidenceSnapshot?.supportRefs.count == 2, "最新快照含两条证据")
    }

    // MARK: W3 确认绑定语义 + 旧别名镜像 + 幂等

    static func testControlServiceConfirmAndMirror() async throws {
        let (repository, _) = try makeRepository()
        let refs = (0..<8).map { event("p\($0)", at: day($0 * 4)) }
        var pattern = try makeRecord(anchor: "night-walk", claimKind: .recurringPattern, evidence: refs, summary: "周末常散步")
        pattern.validFrom = day(0)
        pattern.validTo = day(28)
        // 行为归纳：旧记录本身不能判成熟（无覆盖/反例信息）→ 用知识层直接建成熟修订模拟萃取产出
        let semantic = HoloKnowledgeIngestion.semantic(from: pattern)!
        var evidence = HoloKnowledgeIngestion.evidenceSnapshot(from: pattern, now: day(29))
        evidence.coveragePercent = 1
        evidence.counterexampleSearch = .searchedNoneFound
        evidence.templateID = HoloKnowledgeTemplateID.weeklyRhythm.rawValue
        let revision = HoloKnowledgeRevision.make(
            semantic: semantic, topicLabel: "散步", domains: [.habit], sensitivity: .normal, partition: .normal,
            evidenceSnapshot: evidence, sourceAliases: [pattern.id], createdAt: day(29)
        )
        try await repository.replaceRecordForUserControl(pattern)
        try await repository.saveKnowledgeRevisionAndOperation(revision: revision, operations: [])

        let before = try await repository.resolvedKnowledge(propositionID: revision.propositionID, now: day(30))
        expect(before?.decision == .worthConfirming, "成熟归纳 = 值得确认")
        let asyncCheck1 = try await repository.query(.active).isEmpty
        expect(asyncCheck1, "确认前不可用于回答")
        let service = HoloKnowledgeControlService(repository: repository)
        let request = HoloKnowledgeControlRequest(
            operationID: "confirm-1", propositionID: revision.propositionID,
            expectedSemanticDigest: revision.semanticDigest, knownOperationIDs: [],
            action: .confirm, entry: "memoryCenter", issuedAt: day(30)
        )
        let outcome = try await service.apply(request)
        guard case .applied(_, let undoable) = outcome else { fatalError("确认应生效: \(outcome)") }
        expect(undoable == "confirm-1", "确认可撤销")
        let asyncCheck2 = try await service.apply(request) == .alreadyApplied
        expect(asyncCheck2, "同 operationID 重试 = 幂等成功")
        let after = try await repository.resolvedKnowledge(propositionID: revision.propositionID, now: day(31))
        expect(after?.decision == .confirmedValid, "确认后已记住")
        expect(after?.confirmedSemanticDigest == revision.semanticDigest, "确认绑定语义指纹")
        let legacy = try await repository.fetch(id: pattern.id)
        expect(legacy?.userDecision == .confirmed, "旧记录别名镜像用户决定（旧客户端/旧消费者一致）")
        let asyncCheck3 = try await repository.query(.active).map(\.id) == [pattern.id]
        expect(asyncCheck3, "确认后经别名放行")
        let snapshot = try await repository.knowledgeStoreSnapshot()
        expect(snapshot.operations.contains { $0.kind == .promptRecord }, "共同提示记录（saved）已写")
        let control = try await repository.loadControlState()
        expect(control.userDecisionVersion >= 1, "控制代际推进")
    }

    // MARK: C01 冲突 / C04 遗忘

    static func testControlServiceConflictAndForget() async throws {
        let (repository, _) = try makeRepository()
        let record = try makeRecord(anchor: "tea", claimKind: .explicitPreference, domain: .conversation,
                                    evidence: [statement("t1")], summary: "喜欢喝茶")
        _ = try await repository.upsert(record, observationKey: "o")
        let snapshot = try await repository.knowledgeStoreSnapshot()
        let revision = snapshot.revisions.first!
        let service = HoloKnowledgeControlService(repository: repository)

        let stale = try await service.apply(HoloKnowledgeControlRequest(
            operationID: "c-stale", propositionID: revision.propositionID,
            expectedSemanticDigest: "sd-not-current", knownOperationIDs: [],
            action: .confirm, entry: "memoryCenter", issuedAt: day(1)
        ))
        guard case .conflict(_, let reason) = stale, reason == "semanticChanged" else { fatalError("过期指纹应冲突: \(stale)") }

        let forget = try await service.apply(HoloKnowledgeControlRequest(
            operationID: "forget-1", propositionID: revision.propositionID,
            expectedSemanticDigest: nil, knownOperationIDs: [],
            action: .forget, entry: "memoryCenter", issuedAt: day(2)
        ))
        expect(forget.isSuccess, "遗忘生效")
        let resolved = try await repository.resolvedKnowledge(propositionID: revision.propositionID, now: day(3))
        expect(resolved?.decision == .inactive && resolved?.displayText == "", "遗忘：正文清除，最小阻断")
        let legacy = try await repository.fetch(id: record.id)
        expect(legacy?.userDecision == .forgotten && legacy?.state == .tombstoned, "旧记录镜像遗忘")
        let asyncCheck4 = try await repository.query(.active).isEmpty
        expect(asyncCheck4, "遗忘后不再可用")
        // 遗忘后的放宽（恢复）必须见过遗忘；且遗忘不可被恢复单方解除
        let blindRestore = try await service.apply(HoloKnowledgeControlRequest(
            operationID: "restore-1", propositionID: revision.propositionID,
            expectedSemanticDigest: nil, knownOperationIDs: [],
            action: .restore, entry: "memoryCenter", issuedAt: day(4)
        ))
        guard case .conflict(_, let r2) = blindRestore, r2 == "unseenRestriction" else { fatalError("未见限制的恢复应冲突: \(blindRestore)") }
    }

    // MARK: M01–M04 / M09 迁移分流与幂等

    static func testMigrationIdempotentAndControlFirst() async throws {
        let (repository, _) = try makeRepository()
        // 可靠用户陈述（已确认）
        let stated = try makeRecord(anchor: "brief", claimKind: .explicitPreference, domain: .conversation,
                                    evidence: [statement("b1")], userDecision: .confirmed, summary: "回答简短")
        // 自动低价值单条流水
        let flow = try makeRecord(anchor: "drink", claimKind: .observedFact, domain: .finance,
                                  evidence: [event("tx1", domain: .finance, at: t0)], summary: "买了饮料")
        // 已拒绝（旧不准确）：有正文
        let rejected = try makeRecord(anchor: "rumor", claimKind: .explicitPreference, domain: .conversation,
                                      evidence: [statement("r1")], state: .suppressed, userDecision: .rejected, summary: "喜欢加班")
        // 已遗忘：正文已清
        var forgotten = try makeRecord(anchor: "gone", claimKind: .explicitPreference, domain: .conversation,
                                       evidence: [], state: .tombstoned, userDecision: .forgotten, summary: "x")
        forgotten.displaySummary = ""
        forgotten.aiUseSummary = ""
        for record in [stated, flow, rejected] {
            try await repository.replaceRecordForUserControl(record)
        }
        try await repository.replaceRecordForMigration(forgotten)

        let engine = HoloKnowledgeMigrationEngine(repository: repository)
        let first = try await engine.run(now: day(1))
        expect(first.scanned == 4, "四条全部扫描")
        expect(first.exited == 1, "M02 单条流水退出")
        expect(first.blocked == 2, "M04 阻断类先导入")
        expect(first.committed == 1, "用户陈述提交")

        let second = try await engine.run(now: day(2))
        expect(second.scanned == 0 && second.alreadyProcessed == 4, "M09 重复执行不重复确认或新增知识")

        let snapshot = try await repository.knowledgeStoreSnapshot()
        let receipts = try await repository.knowledgeMigrationReceipts(policyVersion: HoloKnowledgeMigrationEngine.policyVersion)
        expect(receipts.count == 4, "每条旧记录一张收据")
        let statedProp = snapshot.revisions.first { $0.sourceAliases.contains(stated.id) }!.propositionID
        let statedResolved = try await repository.resolvedKnowledge(propositionID: statedProp, now: day(3))
        expect(statedResolved?.decision == .confirmedValid && statedResolved?.confirmedSemanticDigest != nil, "M01 原确认保留且绑定原语义（用户陈述+原确认 = 已确认有效）")

        let rejectedProp = snapshot.revisions.first { $0.sourceAliases.contains(rejected.id) }!.propositionID
        let rejectedResolved = try await repository.resolvedKnowledge(propositionID: rejectedProp, now: day(3))
        expect(rejectedResolved?.decision == .inactive && rejectedResolved?.restrictingOperationIDs.isEmpty == false, "M04 旧不准确导入为限制，不复活")

        expect(!snapshot.revisions.contains { $0.sourceAliases.contains(forgotten.id) }, "M12 遗忘记录不从摘要重建正文")
        expect(receipts.values.contains { $0.legacyRecordID == forgotten.id && $0.status == .restricted }, "遗忘记录保留受限收据")
        expect(!snapshot.revisions.contains { $0.sourceAliases.contains(flow.id) }, "低价值流水不进知识")
        let asyncCheck5 = try await repository.query(.active).map(\.id) == [stated.id]
        expect(asyncCheck5, "迁移后只有用户陈述可用")
    }

    // MARK: M06 逐行隔离

    static func testRowLevelIsolation() async throws {
        let (repository, controller) = try makeRepository()
        let good = try makeRecord(anchor: "good", claimKind: .explicitPreference, domain: .conversation,
                                  evidence: [statement("g")], summary: "正常记录")
        _ = try await repository.upsert(good, observationKey: "g")
        let context = controller.mainContainer.newBackgroundContext()
        try await context.perform {
            let corrupted = NSEntityDescription.insertNewObject(forEntityName: "HoloMemoryRecordMO", into: context) as! HoloMemoryRecordMO
            corrupted.stableID = "holo-memory-v3-corrupted"
            corrupted.recordData = Data("{\"claimKind\":\"futureKind\",\"id\":\"x\"}".utf8)
            corrupted.createdAt = t0
            corrupted.updatedAt = t0
            let unknownKnowledge = NSEntityDescription.insertNewObject(forEntityName: "HoloMemoryKnowledgeRevisionMO", into: context) as! HoloMemoryKnowledgeRevisionMO
            unknownKnowledge.propositionID = "p-unknown"
            unknownKnowledge.semanticRevisionID = "rev-unknown"
            unknownKnowledge.revisionData = Data("not json".utf8)
            unknownKnowledge.createdAt = t0
            try context.save()
        }
        let all = try await repository.query(.all)
        expect(all.map(\.id) == [good.id], "M06 单条损坏不拖垮整批，正常记录可用")
        let snapshot = try await repository.knowledgeStoreSnapshot()
        expect(snapshot.revisions.count == 1, "知识行同样逐行隔离")
    }

    // MARK: S20 / D11 来源失效与复核

    struct StubVerifier: HoloKnowledgeSourceVerifying {
        let status: HoloKnowledgeSourceStatus
        func verify(_ ref: HoloMemoryEvidenceRef) async -> HoloKnowledgeSourceStatus { status }
    }

    static func testSourceInvalidationAndReconcile() async throws {
        let (repository, _) = try makeRepository()
        // 来源关联事实（当前情境）：预算设置
        var budget = try makeRecord(anchor: "budget", claimKind: .observedFact, domain: .finance,
                                    evidence: [HoloMemoryEvidenceRef(id: "b", kind: .entityRef, sourceDomain: .finance,
                                                                     lineageKey: "finance:budget:\(UUID().uuidString)", revisionDigest: "r", observedAt: t0, validFrom: t0)],
                                    summary: "本月餐饮预算 2000")
        budget.validFrom = t0
        _ = try await repository.upsert(budget, observationKey: "b")
        let snapshot = try await repository.knowledgeStoreSnapshot()
        guard let revision = snapshot.revisions.first else { fatalError("有界来源关联事实应形成知识") }
        let asyncCheck6 = try await repository.resolvedKnowledge(propositionID: revision.propositionID, now: day(1))?.decision == .remembered
        expect(asyncCheck6, "来源关联当前情境已记住")
        // 来源删除 → 相应证据退出
        try await repository.saveKnowledgeRevisionAndOperation(revision: nil, operations: [
            HoloKnowledgeOperation(operationID: "inv-1", kind: .sourceInvalidation, propositionID: revision.propositionID,
                                   payload: .sourceInvalidation(sourceRefs: Array(revision.initialEvidenceSnapshot.sourceRevisions.keys), status: "deleted"),
                                   partition: .normal, issuedAt: day(2)),
        ])
        let asyncCheck7 = try await repository.resolvedKnowledge(propositionID: revision.propositionID, now: day(3))?.decision == .inactive
        expect(asyncCheck7, "S20 来源删除后不可用")
        let asyncCheck8 = try await repository.query(.active).isEmpty
        expect(asyncCheck8, "门闸同步生效")
        // 保守 unknown → 复核为 verified 清除
        try await repository.saveKnowledgeRevisionAndOperation(revision: nil, operations: [
            HoloKnowledgeOperation(operationID: "inv-2", kind: .sourceInvalidation, propositionID: revision.propositionID,
                                   payload: .sourceInvalidation(sourceRefs: [], status: "unknown"), partition: .normal, issuedAt: day(4)),
        ])
        let reconciler = HoloKnowledgeSourceReconciler(repository: repository, verifier: StubVerifier(status: .verified))
        let result = try await reconciler.reconcileInvalidated(now: day(5))
        expect(result.reconciled == 1 && result.clearedToVerified == 1, "复核把保守失效收敛")
        // 复核器按真实来源状态重核：来源仍存在 → 之前的删除/未知失效一并清除，知识恢复可用
        let after = try await repository.resolvedKnowledge(propositionID: revision.propositionID, now: day(6))
        expect(after?.decision == .remembered, "真实来源仍存在时复核恢复可用")

        // 复核发现确已删除：按最严重落库，继续不可用
        let deletedReconciler = HoloKnowledgeSourceReconciler(repository: repository, verifier: StubVerifier(status: .deleted))
        try await repository.saveKnowledgeRevisionAndOperation(revision: nil, operations: [
            HoloKnowledgeOperation(operationID: "inv-3", kind: .sourceInvalidation, propositionID: revision.propositionID,
                                   payload: .sourceInvalidation(sourceRefs: [], status: "unknown"), partition: .normal, issuedAt: day(7)),
        ])
        let second = try await deletedReconciler.reconcileInvalidated(now: day(8))
        expect(second.confirmedInvalid == 1, "复核确认失效")
        let asyncCheck9 = try await repository.resolvedKnowledge(propositionID: revision.propositionID, now: day(9))?.decision == .inactive
        expect(asyncCheck9, "确已删除的来源不恢复")
    }

    // MARK: D02 发现来源的修订（无旧别名）走同一确认事务

    static func testDiscoveryOriginRevisionWithoutAlias() async throws {
        let (repository, _) = try makeRepository()
        let refs = (0..<8).map { event("d\($0)", domain: .thought, at: day($0 * 4)) }
        let semantic = HoloKnowledgeSemantic(
            subjectRef: "self", objectRef: "slot-reading", relation: "discovery:bounded_pattern", dimension: "claim:abc",
            applicability: HoloKnowledgeApplicability(windowRule: .absolute(from: day(0), to: day(28))),
            formation: .behavioralInference, evidenceForm: .independentEventSet,
            displayText: "阅读多在周末", aiUseText: "阅读多在周末"
        )
        let evidence = HoloKnowledgeEvidenceSnapshot(
            supportRefs: refs, observationWindowFrom: day(0), observationWindowTo: day(28), independentEventCount: 8,
            coveragePercent: 1, counterexampleSearch: .searchedNoneFound, templateID: HoloKnowledgeTemplateID.weeklyRhythm.rawValue, completePeriods: 4,
            sourceRevisions: Dictionary(refs.map { ($0.lineageKey, $0.revisionDigest) }, uniquingKeysWith: { a, _ in a }), capturedAt: day(29)
        )
        let revision = HoloKnowledgeRevision.make(
            semantic: semantic, topicLabel: "阅读", domains: [.thought], sensitivity: .normal, partition: .normal,
            evidenceSnapshot: evidence,
            origin: HoloKnowledgeOrigin(kind: .discoveryFinding, findingID: "f1", runID: "run", candidateID: "c", claimID: "C01"),
            createdAt: day(29)
        )
        try await repository.saveKnowledgeRevisionAndOperation(revision: revision, operations: [])
        let service = HoloKnowledgeControlService(repository: repository)
        let outcome = try await service.apply(HoloKnowledgeControlRequest(
            operationID: "disc-save-1", propositionID: revision.propositionID,
            expectedSemanticDigest: revision.semanticDigest, knownOperationIDs: [],
            action: .confirm, entry: "discovery", issuedAt: day(30)
        ))
        expect(outcome.isSuccess, "发现处一次确认即保存")
        let resolved = try await repository.resolvedKnowledge(propositionID: revision.propositionID, now: day(31))
        expect(resolved?.decision == .confirmedValid, "两处显示同一已记住状态")
        expect(resolved?.currentRevision?.origin?.kind == .discoveryFinding, "记忆详情可解释形成路径（origin finding/claim）")
        expect(resolved?.legacyAliases.isEmpty == true, "发现来源不依赖旧记录别名")
        let prompts = try await repository.knowledgeStoreSnapshot().operations.filter { $0.kind == .promptRecord }
        expect(prompts.count == 1, "共同提示记录避免同版本跨入口重复询问")
    }
}
