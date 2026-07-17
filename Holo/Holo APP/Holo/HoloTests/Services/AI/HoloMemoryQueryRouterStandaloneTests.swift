import Foundation

actor QueryStoreSpy: HoloMemoryQueryStore {
    let records: [HoloMemoryRecord]
    private(set) var fetchCount = 0

    init(records: [HoloMemoryRecord]) { self.records = records }

    func fetchAvailableMemoryRecords() async throws -> [HoloMemoryRecord] {
        fetchCount += 1
        return records
    }

    func currentFetchCount() -> Int { fetchCount }
}

@main
struct HoloMemoryQueryRouterStandaloneTests {
    private static var assertionCount = 0

    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_752_422_400)
        let finance = try makeRecord(
            domains: [.finance],
            primaryDomain: .finance,
            scope: .domain,
            claimKind: .recurringPattern,
            anchor: .init(type: .merchant, value: "麦当劳"),
            summary: "近期麦当劳消费较频繁",
            freshness: 0.9,
            now: now
        )
        let health = try makeRecord(
            domains: [.health],
            primaryDomain: .health,
            scope: .domain,
            claimKind: .phaseShift,
            anchor: .init(type: .healthMetric, value: "睡眠"),
            summary: "近期睡眠时长偏短",
            freshness: 0.2,
            now: now
        )
        let profile = try makeRecord(
            domains: [.profile],
            primaryDomain: .profile,
            scope: .domain,
            claimKind: .explicitPreference,
            anchor: .init(type: .profile, value: "生活重点"),
            summary: "当前更关注恢复状态",
            freshness: 1,
            now: now
        )
        let goal = try makeRecord(
            domains: [.goal],
            primaryDomain: .goal,
            scope: .domain,
            claimKind: .observedFact,
            anchor: .init(type: .goal, value: "减脂"),
            summary: "正在推进减脂目标",
            freshness: 0.8,
            now: now
        )
        let cross = try makeRecord(
            domains: [.finance, .health],
            primaryDomain: nil,
            scope: .crossDomain,
            claimKind: .association,
            anchor: .init(type: .userTheme, value: "恢复状态"),
            summary: "晚间餐饮偏高与睡眠偏短近期同时出现",
            freshness: 0.7,
            now: now,
            upstreamIDs: [finance.id, health.id]
        )
        var pendingHealth = try makeRecord(
            domains: [.health],
            primaryDomain: .health,
            scope: .domain,
            claimKind: .recurringPattern,
            anchor: .init(type: .healthMetric, value: "待确认心率"),
            summary: "待确认的健康记忆",
            freshness: 1,
            now: now
        )
        pendingHealth.state = .candidate
        let weakFinance = try makeRecord(
            domains: [.finance],
            primaryDomain: .finance,
            scope: .domain,
            claimKind: .recurringPattern,
            anchor: .init(type: .merchant, value: "低分商户"),
            summary: "证据很弱的财务模式",
            freshness: 1,
            confidence: 0.05,
            now: now
        )
        let staleFinance = try makeRecord(
            domains: [.finance],
            primaryDomain: .finance,
            scope: .domain,
            claimKind: .recurringPattern,
            anchor: .init(type: .merchant, value: "过时商户"),
            summary: "已经过时的近期财务状态",
            freshness: 1,
            persistenceClass: .currentState,
            now: now,
            lastSupportedAt: now.addingTimeInterval(-40 * 86_400)
        )
        let allRecords = [
            finance, health, profile, goal, cross,
            pendingHealth, weakFinance, staleFinance
        ]

        let exactIntent = HoloMemoryQueryRouter.route("最近14天吃了多少麦当劳")
        expect(exactIntent.route == .detail, "精确金额/次数问题必须走明细")
        expect(exactIntent.requiresDetailData, "精确问题必须声明明细依赖")
        expect(exactIntent.answerAuthority == .backgroundOnly, "记忆不能回答精确数字")

        let financeIntent = HoloMemoryQueryRouter.route("我最近消费状态如何")
        expect(financeIntent.route == .domainMemory, "消费状态应走财务领域记忆")
        expect(financeIntent.requestedDomains == [.finance], "消费状态只请求财务领域")

        let holisticIntent = HoloMemoryQueryRouter.route("我最近状态如何")
        expect(holisticIntent.route == .holisticMemory, "综合状态应走多领域记忆")
        expect(holisticIntent.includeProfile, "综合状态必须包含个人记忆")
        expect(holisticIntent.includeCrossDomain, "综合状态必须允许跨域记忆")

        let planningIntent = HoloMemoryQueryRouter.route("帮我规划下周")
        expect(planningIntent.route == .planningHybrid, "规划问题应走混合查询")
        expect(planningIntent.requiresDetailData, "规划仍需必要的最新目标/任务明细")

        let semantic = HoloMemoryQuerySemanticContext(
            operation: .summary,
            domains: [.finance],
            claimKinds: [.recurringPattern],
            anchors: [try .init(type: .merchant, value: "麦当劳")],
            timeRange: nil
        )
        let semanticIntent = HoloMemoryQueryRouter.route(
            "review my current pattern",
            semanticContext: semantic
        )
        expect(semanticIntent.route == .domainMemory, "结构化语义应优先于中文关键词")
        expect(semanticIntent.requestedDomains == [.finance], "结构化领域必须被保留")

        let store = QueryStoreSpy(records: allRecords)
        let refresh = HoloMemoryRefreshCoordinator(handler: { _ in })
        let service = HoloMemoryQueryService(
            store: store,
            answeringAllowed: { _ in true },
            refreshCoordinator: refresh
        )

        let detailContext = try await service.query(
            question: "最近14天吃了多少麦当劳",
            now: now
        )
        expect(detailContext.route == .detail, "查询服务必须保留 detail 路由")
        expect(detailContext.answerAuthority == .backgroundOnly, "detail 中记忆只能补背景")
        expect(detailContext.requiresDetailData, "detail context 必须触发明细 fallback")

        let financeContext = try await service.query(
            question: "我最近消费状态如何",
            now: now
        )
        expect(financeContext.records.map(\.id) == [finance.id], "领域查询不应混入无关记忆")
        expect(!financeContext.records.contains(where: {
            $0.id == weakFinance.id || $0.id == staleFinance.id
        }), "低于召回分或新鲜度门槛的记忆不得注入回答")

        let holisticContext = try await service.query(
            question: "我最近状态如何",
            now: now,
            tokenBudget: 220
        )
        expect(holisticContext.records.count <= 8, "普通回答最多选择八条记忆")
        expect(holisticContext.estimatedTokens <= 220, "选择结果必须遵守 token budget")
        expect(holisticContext.records.contains(where: { $0.primaryDomain == .profile }),
               "综合状态应优先带入个人记忆")
        expect(holisticContext.records.contains(where: { $0.scope == .crossDomain }),
               "综合状态应带入合格跨域记忆")

        let planningContext = try await service.query(
            question: "帮我规划下周",
            now: now
        )
        expect(planningContext.requiresDetailData, "规划上下文不能省略最新明细")
        expect(planningContext.records.contains(where: { $0.sourceDomains.contains(.goal) }),
               "规划上下文应包含目标记忆")

        let healthContext = try await service.query(
            question: "最近睡眠状态如何",
            semanticContext: .init(
                operation: .summary,
                domains: [.health],
                claimKinds: [.phaseShift],
                anchors: [],
                timeRange: nil
            ),
            now: now
        )
        expect(healthContext.records.map(\.id) == [health.id], "过期但可用的记忆应先返回")
        expect(!healthContext.records.contains(where: { $0.id == pendingHealth.id }),
               "待确认健康记忆不得进入回答")
        expect(
            healthContext.refreshDecision == .scheduled([.domain(.health)]),
            "低新鲜度记忆应异步安排刷新"
        )

        let newer = try makeRecord(
            domains: [.finance],
            primaryDomain: .finance,
            scope: .domain,
            claimKind: .recurringPattern,
            anchor: .init(type: .merchant, value: "近期商户"),
            summary: "近期餐饮消费较频繁",
            freshness: 1,
            now: now,
            lastSupportedAt: now.addingTimeInterval(-86_400)
        )
        let older = try makeRecord(
            domains: [.finance],
            primaryDomain: .finance,
            scope: .domain,
            claimKind: .recurringPattern,
            anchor: .init(type: .merchant, value: "历史商户"),
            summary: "历史餐饮消费较频繁",
            freshness: 1,
            now: now,
            lastSupportedAt: now.addingTimeInterval(-120 * 86_400)
        )
        let recencyService = HoloMemoryQueryService(
            store: QueryStoreSpy(records: [older, newer]),
            answeringAllowed: { _ in true },
            refreshCoordinator: refresh
        )
        let recencyContext = try await recencyService.query(
            question: "我最近消费状态如何",
            now: now
        )
        expect(recencyContext.records.map(\.id).first == newer.id,
               "其余条件一致时，最近被证据支持的记忆必须优先")

        let disabledStore = QueryStoreSpy(records: allRecords)
        let disabledService = HoloMemoryQueryService(
            store: disabledStore,
            answeringAllowed: { _ in false },
            refreshCoordinator: refresh
        )
        let disabled = try await disabledService.query(question: "我最近状态如何", now: now)
        expect(disabled.records.isEmpty, "关闭记忆辅助后必须返回空上下文")
        expect(disabled.refreshDecision == .disabled, "关闭后不得静默刷新")
        let disabledFetchCount = await disabledStore.currentFetchCount()
        expect(disabledFetchCount == 0, "关闭后不得读取记忆仓库")

        print("HoloMemoryQueryRouterStandaloneTests passed: \(assertionCount) assertions")
    }

    private static func makeRecord(
        domains: [HoloMemoryDomain],
        primaryDomain: HoloMemoryDomain?,
        scope: HoloMemoryScope,
        claimKind: HoloMemoryClaimKind,
        anchor: HoloMemoryAnchorRef,
        summary: String,
        freshness: Double,
        confidence: Double = 0.8,
        persistenceClass: HoloMemoryPersistenceClass = .phase,
        now: Date,
        lastSupportedAt: Date? = nil,
        upstreamIDs: [String] = []
    ) throws -> HoloMemoryRecord {
        let evidence = domains.enumerated().map { index, domain in
            HoloMemoryEvidenceRef(
                id: "evidence-\(domain.rawValue)-\(index)-\(anchor.canonicalValue)",
                kind: .aggregateSnapshot,
                sourceDomain: domain,
                lineageKey: "lineage-\(domain.rawValue)-\(anchor.canonicalValue)",
                revisionDigest: "rev-1",
                observedAt: now.addingTimeInterval(-86_400),
                validFrom: now.addingTimeInterval(-14 * 86_400),
                validTo: now,
                aggregateDefinition: "query-test",
                sampleCount: 14,
                summary: summary
            )
        }
        let id = try HoloMemoryIdentity.makeStableID(
            scope: scope,
            primaryDomain: primaryDomain,
            sourceDomains: domains,
            claimKind: claimKind,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: id,
            scope: scope,
            primaryDomain: primaryDomain,
            sourceDomains: domains,
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: claimKind,
            persistenceClass: persistenceClass,
            displaySummary: summary,
            aiUseSummary: summary,
            prohibitedInferences: [],
            evidenceRefs: evidence,
            upstreamMemoryIDs: upstreamIDs,
            counterEvidenceRefs: [],
            validFrom: now.addingTimeInterval(-14 * 86_400),
            validTo: now,
            lastSupportedAt: lastSupportedAt ?? now.addingTimeInterval(-86_400),
            confidenceScore: confidence,
            freshnessScore: freshness,
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: domains.contains(.health) ? .sensitive : .normal,
            userDecision: .none,
            createdAt: now.addingTimeInterval(-14 * 86_400),
            updatedAt: now
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }
}
