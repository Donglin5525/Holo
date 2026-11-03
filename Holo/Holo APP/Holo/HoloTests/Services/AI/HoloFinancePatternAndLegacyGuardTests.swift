import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloFinancePatternAndLegacyGuardTests.main()
    }
}
#endif

/// 2026-11-01 记忆修复批的确定性场景：
/// ① formation 读取端防线（错标 explicitUserStatement 只认对话域、业务域 declared 降级）；
/// ② 存量大扫除第二/三刀（分类驱动 + 单笔流水扩域）；
/// ③ legacyRetire 退役操作（种类语义 + 解析器 inactive）；
/// ④ 财务规律挖矿引擎（门槛/覆盖率/新鲜度/固定支出排除/幂等 + 统一准入值得确认闭环）。
struct HoloFinancePatternAndLegacyGuardTests {
    private static var assertionCount = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertionCount += 1
        if !condition() { fatalError("[FinancePatternLegacyGuard] \(message)") }
    }

    private static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private static func day(_ n: Int) -> Date { t0.addingTimeInterval(TimeInterval(n) * 86_400) }

    // MARK: 构造

    private static func ref(
        _ key: String,
        domain: HoloMemoryDomain,
        at: Date,
        kind: HoloMemoryEvidenceKind = .entityRef
    ) -> HoloMemoryEvidenceRef {
        HoloMemoryEvidenceRef(
            id: "e-\(domain.rawValue)-\(key)",
            kind: kind,
            sourceDomain: domain,
            lineageKey: "\(domain.rawValue):\(key)",
            sourceID: "\(domain.rawValue):\(key)",
            revisionDigest: "r-\(key)",
            observedAt: at
        )
    }

    private static func makeRecord(
        anchor: String,
        claimKind: HoloMemoryClaimKind,
        domain: HoloMemoryDomain,
        evidence: [HoloMemoryEvidenceRef],
        state: HoloMemoryState = .active,
        userDecision: HoloMemoryUserDecision = .none,
        sensitivity: HoloMemorySensitivity = .normal,
        summary: String? = nil,
        payload: HoloPersonalContextPayloadV1? = nil
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
            lastSupportedAt: t0, confidenceScore: 0.8, freshnessScore: 1,
            scoringVersion: HoloMemoryScorer.currentVersion, scoreComputedAt: t0,
            extractorVersion: 1, promptVersion: 1, state: state,
            sensitivity: sensitivity, userDecision: userDecision,
            createdAt: t0, updatedAt: t0,
            personalContext: payload.map { HoloPersonalContextPayloadEnvelope(v1: $0) }
        )
    }

    private static func payload(
        statement: String,
        epistemic: HoloContextEpistemicStatus,
        basisSourceIDs: [String]
    ) -> HoloPersonalContextPayloadV1 {
        HoloPersonalContextPayloadV1(
            contextID: UUID().uuidString,
            statement: statement,
            relationText: "相关",
            epistemicStatus: epistemic,
            basis: basisSourceIDs.map {
                HoloContextBasisRef(sourceID: $0, sourceRevision: "rev-\($0)")
            },
            admission: HoloContextAdmissionV1(
                level: .confirmationOnly,
                policyVersion: 4,
                decidedAt: t0
            )
        )
    }

    static func main() async throws {
        try testFormationReadSideGuard()
        try testSweepPolicySecondThirdKnives()
        try testLegacyRetireOperationSemantics()
        try testLegacyRetireResolverInactive()
        try testMinerThresholds()
        try testMinerAdmissionAndIdempotency()
        print("✅ HoloFinancePatternAndLegacyGuardTests 全部通过（\(assertionCount) 断言）")
    }

    // MARK: ① formation 读取端防线

    static func testFormationReadSideGuard() throws {
        // 错标存量：财务域证据被标成「用户原话」→ 不得再判直接陈述。
        let mislabeled = try makeRecord(
            anchor: "麦当劳晚餐", claimKind: .observedFact, domain: .finance,
            evidence: [ref("tx1", domain: .finance, at: day(1), kind: .explicitUserStatement)],
            summary: "用户 2026-07-29 有一笔晚餐支出，地点为麦当劳。"
        )
        expect(
            HoloKnowledgeIngestion.formation(for: mislabeled, payload: nil) == .sourceLinked,
            "错标 explicitUserStatement + 财务域 → 按观察事实（sourceLinked），不再当用户原话"
        )
        expect(
            HoloKnowledgeLegacyAdapter.classify(mislabeled) == .autoLowValue,
            "单证据观察事实 → 自动低价值（主列表退出）"
        )

        // 真用户原话：对话域 explicitUserStatement 仍直接陈述。
        let chatStatement = try makeRecord(
            anchor: "演唱会偏好", claimKind: .explicitPreference, domain: .conversation,
            evidence: [ref("m1", domain: .conversation, at: day(1), kind: .explicitUserStatement)],
            summary: "用户表示钱主要花在旅游和看演唱会上。"
        )
        expect(
            HoloKnowledgeLegacyAdapter.classify(chatStatement) == .reliableUserStatement,
            "对话域用户原话 → 可靠用户陈述（保留展示）"
        )

        // 业务域 declared 降级：模型把账单内容当「用户明说」。
        let declaredOnFinance = try makeRecord(
            anchor: "麦当劳偏好", claimKind: .explicitPreference, domain: .finance,
            evidence: [ref("tx2", domain: .finance, at: day(2), kind: .explicitUserStatement)],
            summary: "用户在麦当劳用餐。",
            payload: payload(
                statement: "用户在麦当劳用餐",
                epistemic: .declared,
                basisSourceIDs: ["finance:AAA"]
            )
        )
        expect(
            HoloKnowledgeIngestion.formation(for: declaredOnFinance, payload: declaredOnFinance.personalContext?.v1)
                == .sourceLinked,
            "财务来源 declared → 降级 sourceLinked（不是用户明说）"
        )

        // 用户亲写想法上的 declared 保持直接陈述。
        let declaredOnThought = try makeRecord(
            anchor: "先记录再分析", claimKind: .explicitPreference, domain: .thought,
            evidence: [ref("t1", domain: .thought, at: day(3))],
            summary: "用户认同先记录再分析。",
            payload: payload(
                statement: "用户认同先记录再分析",
                epistemic: .declared,
                basisSourceIDs: ["BBB"] // 无前缀 = thought 存量键
            )
        )
        expect(
            HoloKnowledgeIngestion.formation(for: declaredOnThought, payload: declaredOnThought.personalContext?.v1)
                == .directExpression,
            "想法域 declared → 直接陈述（用户亲写）"
        )

        // 模型给财务流水贴的「偏好」标签：无用户原话证据时不当直接陈述。
        let financePreference = try makeRecord(
            anchor: "麦当劳", claimKind: .explicitPreference, domain: .finance,
            evidence: [ref("tx3", domain: .finance, at: day(4))],
            summary: "用户爱吃麦当劳。"
        )
        expect(
            HoloKnowledgeIngestion.formation(for: financePreference, payload: nil) == .sourceLinked,
            "财务域 explicitPreference（无原话证据）→ sourceLinked"
        )
        expect(
            HoloKnowledgeLegacyAdapter.classify(financePreference) == .autoInferenceUnconfirmed,
            "单证据财务偏好 → 未确认推断（主列表退出，等统计引擎）"
        )
    }

    // MARK: ② 大扫除第二/三刀

    static func testSweepPolicySecondThirdKnives() throws {
        // 未确认推断的 active 记录（打磨 Holo 类）→ 第三刀收进历史。
        let hypothesisJunk = try makeRecord(
            anchor: "打磨Holo", claimKind: .hypothesis, domain: .task,
            evidence: [ref("task1", domain: .task, at: day(1)), ref("task2", domain: .task, at: day(2))],
            summary: "用户可能持续在打磨 Holo 产品。"
        )
        expect(HoloLegacySweepPolicy.shouldSweep(hypothesisJunk), "分类驱动的未确认推断 → 收进历史")

        // 单日打卡碎片（带「至」跨期词但真实跨度只有两天）→ 第三刀兜住（第一/二刀漏网）。
        let checkinFragment = try makeRecord(
            anchor: "戒烟", claimKind: .recurringPattern, domain: .habit,
            evidence: [ref("h1", domain: .habit, at: day(1)), ref("h2", domain: .habit, at: day(1))],
            summary: "用户有「戒烟」打卡项，2026-03-25 至 2026-03-26 期间多次完成打卡。"
        )
        expect(HoloLegacySweepPolicy.shouldSweep(checkinFragment), "打卡碎片（分类驱动）→ 收进历史")

        // 保护：用户确认过的规律不碰。
        let confirmedPattern = try makeRecord(
            anchor: "烟酒", claimKind: .recurringPattern, domain: .finance,
            evidence: [ref("agg1", domain: .finance, at: day(5), kind: .aggregateSnapshot)],
            userDecision: .confirmed,
            summary: "过去3个月烟酒支出共16笔，总计1650元。"
        )
        expect(!HoloLegacySweepPolicy.shouldSweep(confirmedPattern), "用户确认过的规律 → 不碰")

        // 保护：敏感内容不碰。
        let sensitive = try makeRecord(
            anchor: "敏感", claimKind: .hypothesis, domain: .thought,
            evidence: [ref("s1", domain: .thought, at: day(1))],
            sensitivity: .sensitive,
            summary: "敏感推断"
        )
        expect(!HoloLegacySweepPolicy.shouldSweep(sensitive), "敏感内容 → 不碰")

        // 第一刀扩域：对话里「记了一笔 X」转述的单笔消费（财务库之外）也收。
        let chatExpense = try makeRecord(
            anchor: "猫砂", claimKind: .observedFact, domain: .conversation,
            evidence: [ref("m2", domain: .conversation, at: day(6), kind: .explicitUserStatement)],
            summary: "用户 2026-04-16 记录了一笔 170 元的猫砂支出。"
        )
        expect(HoloLegacySweepPolicy.shouldSweep(chatExpense), "对话域单笔流水报告（扩域第一刀）→ 收进历史")

        // 第一刀不误伤多证据聚合（≥4 证据的观察事实不动，交给分类刀判断）。
        let aggregateObserved = try makeRecord(
            anchor: "餐饮结构", claimKind: .observedFact, domain: .finance,
            evidence: (1...5).map { ref("agg\($0)", domain: .finance, at: day($0)) },
            summary: "用户 2026-07-15 至 2026-07-19 期间记录了晚餐、饮品等多笔支出。"
        )
        expect(
            !HoloLegacySweepPolicy.isSingleExpenseFlow(aggregateObserved),
            "多证据聚合不被第一刀句式误伤（由分类刀裁决）"
        )
    }

    // MARK: ③ legacyRetire 操作语义

    static func testLegacyRetireOperationSemantics() throws {
        expect(HoloKnowledgeOperationKind.legacyRetire.rawValue == "legacyRetire", "退役种类 rawValue")
        expect(HoloKnowledgeOperationKind.knownCases.contains(.legacyRetire), "退役种类进已知清单")
        expect(HoloKnowledgeOperationKind.legacyRetire.isUsageRestricting, "退役 = 使用限制")
        expect(!HoloKnowledgeOperationKind.legacyRetire.isUserAuthority, "退役 = 系统操作非用户权威")
        expect(
            HoloKnowledgeOperationKind(rawValue: "legacyRetire") == .legacyRetire,
            "rawValue 往返"
        )
        // 旧端兼容：未识别时按 unknownPreserved 保守限制（09-R06 已有语义）。
        expect(
            HoloKnowledgeOperationKind(rawValue: "legacyRetire")?.isUsageRestricting == true,
            "旧端解码路径同样限制使用"
        )
    }

    static func testLegacyRetireResolverInactive() throws {
        let semantic = HoloKnowledgeSemantic(
            subjectRef: "self", objectRef: "slot:麦当劳", relation: "finance:merchantFrequency",
            polarity: true, objectValue: nil, dimension: "claim:recurringPattern",
            qualifiers: [], applicability: HoloKnowledgeApplicability(windowRule: .ongoing),
            formation: .directExpression, evidenceForm: .explicitSemanticFact,
            displayText: "旧口径导入的单笔流水", aiUseText: "旧口径导入的单笔流水"
        )
        let revision = HoloKnowledgeRevision.make(
            semantic: semantic, topicLabel: "麦当劳", domains: [.finance],
            sensitivity: .normal, partition: .normal,
            evidenceSnapshot: HoloKnowledgeEvidenceSnapshot(
                supportRefs: [ref("old1", domain: .finance, at: t0)],
                counterRefs: [], observationWindowFrom: t0, observationWindowTo: t0,
                independentEventCount: 1, coveragePercent: nil,
                counterexampleSearch: .notSearched, templateID: nil,
                sourceRevisions: [:], capturedAt: t0
            ),
            createdAt: t0
        )
        let retire = HoloKnowledgeOperation(
            operationID: "legacy-retire-r1",
            kind: .legacyRetire,
            propositionID: revision.propositionID,
            controlGeneration: 1,
            payload: .none,
            partition: .normal,
            issuedAt: day(1)
        )
        let snapshot = HoloKnowledgeResolutionSnapshot(
            propositionID: revision.propositionID,
            revisions: [revision],
            operations: [retire],
            sourceStatus: .verified,
            controlGeneration: 1,
            learningBaselineAt: nil,
            hasUnreadableData: false,
            now: day(2)
        )
        let resolved = HoloKnowledgeResolver.resolve(snapshot)
        expect(resolved?.decision == .inactive, "退役操作 → 命题停用")
        expect(resolved?.decisionReasons.contains("legacyRetired") == true, "停用理由 = legacyRetired")
        expect(resolved?.allowedUses.isEmpty == true, "退役后不用于回答")

        // restore 不能解除退役（只解除停用类；退役只能由复评口径变化收回）。
        let restore = HoloKnowledgeOperation(
            operationID: "restore-1", kind: .restore,
            propositionID: revision.propositionID,
            priorOperationIDs: [retire.operationID],
            controlGeneration: 1, payload: .none, partition: .normal, issuedAt: day(3)
        )
        let restored = HoloKnowledgeResolver.resolve(
            HoloKnowledgeResolutionSnapshot(
                propositionID: revision.propositionID,
                revisions: [revision], operations: [retire, restore],
                sourceStatus: .verified, controlGeneration: 1,
                learningBaselineAt: nil, hasUnreadableData: false, now: day(4)
            )
        )
        expect(restored?.decision == .inactive, "restore 不解除退役")
    }

    // MARK: ④ 财务规律挖矿

    private static func tx(
        _ i: Int,
        merchant: String,
        amount: Double,
        at: Date
    ) -> FinanceMemoryTransactionInput {
        FinanceMemoryTransactionInput(
            id: String(format: "A%08d-0000-0000-0000-000000000000", i),
            amount: amount, isExpense: true,
            categoryID: "cat-1", categoryName: "餐饮",
            merchant: merchant, occurredAt: at,
            revisionDigest: "rev-\(i)"
        )
    }

    static func testMinerThresholds() throws {
        // 周节奏：20 周 20 笔（每周一）→ weeklyRhythm + 覆盖率 ≥ 0.7。
        // now 须落在最后一笔（day 133）的 recentLapseDays(45) 内，否则被新鲜度把关正确拦下（下方有独立反向用例）。
        let now = day(140)
        let weekly = (0..<20).map { tx($0, merchant: "麦当劳", amount: Double(35 + $0 % 10), at: day($0 * 7)) }
        let weeklyCandidates = HoloFinancePatternMiner.mine(transactions: weekly, now: now)
        expect(weeklyCandidates.count == 1, "周节奏候选产出 1 条（实际 \(weeklyCandidates.count) 条：\(weeklyCandidates.map { "\($0.template)/\($0.transactions.count)笔/cov=\($0.coveragePercent.map { String(format: "%.2f", $0) } ?? "nil")" })）")
        if let c = weeklyCandidates.first {
            expect(c.template == .weeklyRhythm, "密节奏 → weeklyRhythm 模板")
            expect((c.coveragePercent ?? 0) >= 0.7, "覆盖率达标")
            expect(c.transactions.count == 20, "独立事件 20 笔")
        }

        // 稀节奏（麦当劳真数据形态：5 个月 20 笔但中间有空档）→ periodicRule。
        var sparseDates: [Int] = [0, 8, 40, 42, 45, 48, 55, 56, 63, 66, 71, 105, 108, 112, 121, 122, 124, 133, 141]
        sparseDates.append(147)
        let sparse = sparseDates.enumerated().map {
            tx(100 + $0.offset, merchant: "麦当劳", amount: Double(32 + $0.offset % 12), at: day($0.element))
        }
        let sparseCandidates = HoloFinancePatternMiner.mine(transactions: sparse, now: day(150))
        expect(sparseCandidates.count == 1, "稀节奏候选产出 1 条")
        if let c = sparseCandidates.first {
            expect(c.template == .periodicRule, "稀节奏（覆盖率不足周模板）→ periodicRule 月度模板")
            expect(c.coveragePercent == nil, "月度模板不要求覆盖率")
        }

        // 新鲜度：最近一笔超 45 天 → 不出候选（规律可能已停）。
        let stale = (0..<8).map { tx(200 + $0, merchant: "健身房", amount: 99, at: day($0 * 7)) }
        expect(
            HoloFinancePatternMiner.mine(transactions: stale, now: day(200)).isEmpty,
            "最近一笔超 45 天 → 不出候选"
        )

        // 金额稳定（±10%）→ 交给固定支出信号，不重复挖。
        let stable = (0..<8).map { tx(300 + $0, merchant: "AppleCare", amount: 191.6, at: day($0 * 7)) }
        expect(
            HoloFinancePatternMiner.mine(transactions: stable, now: day(60)).isEmpty,
            "金额稳定的分期/固定支出 → 跳过（固定支出信号负责）"
        )

        // 样本不足 → 不出。
        let few = (0..<2).map { tx(400 + $0, merchant: "便利店", amount: 12, at: day($0 * 30)) }
        expect(HoloFinancePatternMiner.mine(transactions: few, now: day(70)).isEmpty, "样本不足 → 不出")

        // 上限：多商家同时达标时一轮最多 5 条。
        let many = (0..<7).flatMap { brand in
            (0..<7).map { offset in
                tx(500 + brand * 10 + offset, merchant: "商家\(brand)", amount: Double(20 + brand), at: day(offset * 7))
            }
        }
        expect(
            HoloFinancePatternMiner.mine(transactions: many, now: day(50)).count
                <= HoloFinancePatternMiner.maxCandidatesPerRun,
            "单轮候选数不超上限"
        )

        // 商家缺名的流水不参与（无备注账单不挖）。
        let noMerchant = (0..<8).map {
            FinanceMemoryTransactionInput(
                id: "N\($0)", amount: 30, isExpense: true, categoryID: "c", categoryName: "餐饮",
                merchant: nil, occurredAt: day($0 * 7), revisionDigest: "r"
            )
        }
        expect(HoloFinancePatternMiner.mine(transactions: noMerchant, now: day(60)).isEmpty, "无商家名 → 不挖")
    }

    static func testMinerAdmissionAndIdempotency() throws {
        // 端到端闭环：挖矿产物 → 统一准入 = 值得确认；解析器 = worthConfirming。
        // now 同上：须在最后一笔 45 天新鲜度窗口内。
        let now = day(140)
        let weekly = (0..<20).map { tx($0, merchant: "麦当劳", amount: Double(35 + $0 % 10), at: day($0 * 7)) }
        guard let candidate = HoloFinancePatternMiner.mine(transactions: weekly, now: now).first else {
            return expect(false, "挖矿应有候选")
        }
        let semantic = HoloFinancePatternMiner.semantic(for: candidate)
        let evidence = HoloFinancePatternMiner.evidenceSnapshot(for: candidate, now: now)
        expect(evidence.counterexampleSearch == .searchedNoneFound, "新鲜度已查 → 如实 searchedNoneFound")
        expect(evidence.templateID == HoloKnowledgeTemplateID.weeklyRhythm.rawValue, "证据快照带模板登记")
        expect(evidence.independentEventCount == 20, "独立事件 = 逐笔交易")

        let verdict = HoloKnowledgeAdmission.assess(
            semantic: semantic, evidence: evidence, authorizedSourceDomains: [.finance]
        )
        expect(verdict == .worthConfirming, "统一准入 → 值得确认（此前结构性不可能）")

        let revision = HoloKnowledgeRevision.make(
            semantic: semantic, topicLabel: candidate.displayLabel, domains: [.finance],
            sensitivity: .normal, partition: .normal, evidenceSnapshot: evidence,
            createdAt: candidate.transactions.last!.occurredAt
        )
        let resolved = HoloKnowledgeResolver.resolve(
            HoloKnowledgeResolutionSnapshot(
                propositionID: revision.propositionID, revisions: [revision], operations: [],
                sourceStatus: .verified, controlGeneration: 1, learningBaselineAt: nil,
                hasUnreadableData: false, now: now
            )
        )
        expect(resolved?.decision == .worthConfirming, "解析器 → 值得确认（进「值得确认」区）")

        // 幂等：同数据重挖 → 同命题同修订同证据操作（ID 全部内容决定）。
        let writes1 = HoloFinancePatternMiner.knowledgeWrites(for: candidate, controlGeneration: 1, now: now)
        let writes2 = HoloFinancePatternMiner.knowledgeWrites(for: candidate, controlGeneration: 1, now: day(201))
        expect(
            writes1.revision.semanticRevisionID == writes2.revision.semanticRevisionID,
            "重挖同模式 → 修订 ID 稳定（不产生重复命题）"
        )
        expect(
            writes1.operations.map(\.operationID) == writes2.operations.map(\.operationID),
            "重挖同模式 → 证据操作 ID 稳定（幂等）"
        )
        // 文案克制：不出现技术记号。
        expect(
            !HoloFinancePatternMiner.displayText(for: candidate).contains("entityRef")
                && !HoloFinancePatternMiner.displayText(for: candidate).contains("JSON"),
            "文案面向用户无技术记号"
        )
    }
}
