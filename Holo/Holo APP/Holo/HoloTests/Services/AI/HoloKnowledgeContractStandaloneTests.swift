import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        HoloKnowledgeContractStandaloneTests.main()
    }
}
#endif

/// 通用知识契约与统一决策的确定性场景（方案 v2.2 场景矩阵：S/C/U 子集）。
/// 纯值类型测试：身份与指纹、准入模板、解析器控制代数、Codable 容错。
struct HoloKnowledgeContractStandaloneTests {
    private static var assertionCount = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertionCount += 1
        if !condition() { fatalError("[HoloKnowledgeContract] \(message)") }
    }

    private static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private static func day(_ n: Int) -> Date { t0.addingTimeInterval(TimeInterval(n) * 86_400) }

    private static func ref(_ key: String, domain: HoloMemoryDomain = .habit, at: Date, kind: HoloMemoryEvidenceKind = .entityRef) -> HoloMemoryEvidenceRef {
        HoloMemoryEvidenceRef(
            id: "e-\(key)", kind: kind, sourceDomain: domain, lineageKey: "\(domain.rawValue):\(key)",
            sourceID: key, revisionDigest: "r-\(key)", observedAt: at
        )
    }

    private static func semantic(
        object: String = "slot-reading",
        relation: String = "likes",
        polarity: Bool = true,
        value: String? = nil,
        dimension: String = "facet:preference",
        condition: String? = nil,
        window: HoloKnowledgeApplicability.WindowRule = .ongoing,
        formation: HoloKnowledgeFormation = .directExpression,
        form: HoloKnowledgeEvidenceForm = .explicitSemanticFact,
        display: String = "喜欢阅读"
    ) -> HoloKnowledgeSemantic {
        HoloKnowledgeSemantic(
            subjectRef: "self", objectRef: object, relation: relation, polarity: polarity,
            objectValue: value, dimension: dimension,
            applicability: HoloKnowledgeApplicability(windowRule: window, conditionText: condition),
            formation: formation, evidenceForm: form, displayText: display, aiUseText: display
        )
    }

    private static func snapshot(
        refs: [HoloMemoryEvidenceRef],
        counter: [HoloMemoryEvidenceRef] = [],
        events: Int? = nil,
        coverage: Double? = nil,
        search: HoloKnowledgeCounterexampleSearchStatus = .notSearched,
        template: HoloKnowledgeTemplateID? = nil,
        completePeriods: Int? = nil,
        capturedAt: Date = t0
    ) -> HoloKnowledgeEvidenceSnapshot {
        let dates = refs.map(\.observedAt)
        return HoloKnowledgeEvidenceSnapshot(
            supportRefs: refs, counterRefs: counter,
            observationWindowFrom: dates.min(), observationWindowTo: dates.max(),
            independentEventCount: events ?? Set(refs.map(\.lineageKey)).count,
            coveragePercent: coverage, counterexampleSearch: search,
            templateID: template?.rawValue, completePeriods: completePeriods,
            sourceRevisions: Dictionary(refs.map { ($0.lineageKey, $0.revisionDigest) }, uniquingKeysWith: { a, _ in a }),
            capturedAt: capturedAt
        )
    }

    private static func revision(_ s: HoloKnowledgeSemantic, evidence: HoloKnowledgeEvidenceSnapshot, aliases: [String] = ["legacy-1"], at: Date = t0) -> HoloKnowledgeRevision {
        HoloKnowledgeRevision.make(
            semantic: s, topicLabel: "阅读", domains: [.habit], sensitivity: .normal, partition: .normal,
            evidenceSnapshot: evidence, sourceAliases: aliases, createdAt: at
        )
    }

    private static func op(_ id: String, _ kind: HoloKnowledgeOperationKind, prop: String, digest: String? = nil, priors: Set<String> = [], payload: HoloKnowledgeOperationPayload = .none, at: Date) -> HoloKnowledgeOperation {
        HoloKnowledgeOperation(
            operationID: id, kind: kind, propositionID: prop, targetSemanticDigest: digest,
            priorOperationIDs: priors, payload: payload, partition: .normal, issuedAt: at
        )
    }

    private static func resolve(_ revisions: [HoloKnowledgeRevision], _ ops: [HoloKnowledgeOperation], source: HoloKnowledgeSourceStatus = .verified, baseline: Date? = nil, now: Date = day(60)) -> HoloResolvedKnowledge? {
        HoloKnowledgeResolver.resolve(HoloKnowledgeResolutionSnapshot(
            propositionID: revisions.first!.propositionID, revisions: revisions, operations: ops,
            sourceStatus: source, learningBaselineAt: baseline, now: now
        ))
    }

    static func main() {
        testIdentityAndDigest()
        testAdmissionDirectAndTemporary()
        testAdmissionTemplates()
        testResolverConfirmBinding()
        testResolverControlAlgebra()
        testResolverSourceAndBaseline()
        testOperationPayloadCodable()
        testPartitionPolicy()
        testPersistedSourceStatus()
        print("HoloKnowledgeContractStandaloneTests passed (\(assertionCount) assertions)")
    }

    // MARK: S32 / §2.4 身份与指纹

    static func testIdentityAndDigest() {
        let a = semantic(object: "slot-short-answer", relation: "prefers", dimension: "facet:preference", display: "我喜欢短回答")
        let b = semantic(object: "slot-hiking", relation: "likes", dimension: "facet:preference", display: "也喜欢徒步")
        expect(HoloKnowledgeIdentity.propositionID(for: a) != HoloKnowledgeIdentity.propositionID(for: b),
               "S32：同 claimKind 不同对象必须是两个命题")

        let reworded = semantic(display: "我很喜欢读书")
        expect(semantic().semanticDigest == reworded.semanticDigest, "措辞变化不产生独立语义版本")

        let valued = semantic(value: "5000 CNY/月")
        expect(semantic().semanticDigest != valued.semanticDigest, "关键对象值属于语义：5000 改变指纹")

        let negated = semantic(polarity: false)
        expect(semantic().semanticDigest != negated.semanticDigest, "否定改变语义版本")
        expect(HoloKnowledgeIdentity.propositionID(for: negated) == HoloKnowledgeIdentity.propositionID(for: semantic()),
               "肯/否定是同一命题的不同语义版本")

        let monthWindow = semantic(window: .absolute(from: day(0), to: day(30)))
        let longTerm = semantic(window: .ongoing)
        expect(monthWindow.semanticDigest != longTerm.semanticDigest, "S47：把一个月扩成长期必须改变语义版本")

        let conditioned = semantic(condition: "出差期间")
        expect(HoloKnowledgeIdentity.propositionID(for: conditioned) != HoloKnowledgeIdentity.propositionID(for: semantic()),
               "适用条件参与命题身份")

        let revA = revision(semantic(), evidence: snapshot(refs: [ref("1", at: t0)]))
        let revA2 = revision(semantic(display: "换个说法"), evidence: snapshot(refs: [ref("2", at: t0)]))
        expect(revA.semanticRevisionID == revA2.semanticRevisionID, "同命题同指纹同别名 → 确定性修订 ID（重试/同步重复行可归并）")

        let topic1 = HoloKnowledgeIdentity.topicID(objectRef: "slot-reading", dimension: "facet:preference")
        let topic2 = HoloKnowledgeIdentity.topicID(objectRef: "slot-reading", dimension: "facet:responsibility")
        expect(topic1 != topic2, "主题按对象×维度分组")
    }

    // MARK: S31 / S34 / S01 / S29 直接陈述与一次性范围

    static func testAdmissionDirectAndTemporary() {
        let all = Set(HoloMemoryDomain.allCases)
        let userRef = ref("say-1", domain: .conversation, at: t0, kind: .explicitUserStatement)

        // S31「以后都简短一点」= 持续偏好
        let persistent = semantic(object: "slot-brevity", relation: "prefers", display: "以后都简短一点")
        expect(HoloKnowledgeAdmission.assess(semantic: persistent, evidence: snapshot(refs: [userRef]), authorizedSourceDomains: all) == .remembered,
               "S31 持续偏好直接记住")

        // S31「今天简短一点」= 本次范围：窗口终点落在捕获时刻附近
        let tonight = semantic(object: "slot-brevity", relation: "prefers", window: .absolute(from: t0, to: t0.addingTimeInterval(3600 * 6)), display: "今天简短一点")
        expect(HoloKnowledgeAdmission.assess(semantic: tonight, evidence: snapshot(refs: [userRef], capturedAt: t0), authorizedSourceDomains: all) == .internalOnly(reason: .temporaryScopeOnly),
               "S31 今天/今晚不长期化")

        // S34「记住去年那次旅行对我很重要」= 过去的重要事件，不要求重复
        let trip = semantic(object: "slot-trip", relation: "important-event", dimension: "facet:state", window: .absolute(from: day(-400), to: day(-390)), display: "去年那次旅行对我很重要")
        expect(HoloKnowledgeAdmission.assess(semantic: trip, evidence: snapshot(refs: [userRef], capturedAt: t0), authorizedSourceDomains: all) == .remembered,
               "S34 过去重要事件直接保留")

        // S01 一笔便利店饮料：来源关联的单条流水无个人记忆
        let drink = semantic(object: "slot-drink", relation: "purchased", dimension: "claim:observedFact", formation: .sourceLinked, form: .independentEventSet, display: "买了一瓶饮料")
        expect(HoloKnowledgeAdmission.assess(semantic: drink, evidence: snapshot(refs: [ref("tx-1", domain: .finance, at: t0)]), authorizedSourceDomains: all) == .internalOnly(reason: .routineFlowWithoutValue),
               "S01 单条流水退出")

        // S29 第三方主体不形成个人记忆
        var third = semantic(display: "妹妹喜欢猫")
        third.subjectRef = "person-sister"
        expect(HoloKnowledgeAdmission.assess(semantic: third, evidence: snapshot(refs: [userRef]), authorizedSourceDomains: all) == .reject(reason: .thirdPartyNotAuthorized),
               "S29 第三方画像不建")

        // 来源授权：发现只授权三域
        let financeFact = semantic(formation: .sourceLinked, form: .explicitSemanticFact, display: "预算 3000")
        expect(HoloKnowledgeAdmission.assess(semantic: financeFact, evidence: snapshot(refs: [ref("b", domain: .finance, at: t0)]), authorizedSourceDomains: [.thought, .task, .habit]) == .reject(reason: .sourceNotAuthorized),
               "D12 八域记忆不扩大发现授权")
    }

    // MARK: S08 / S43 / S48 行为归纳模板

    static func testAdmissionTemplates() {
        let all = Set(HoloMemoryDomain.allCases)
        let pattern = semantic(object: "slot-run", relation: "weekly-rhythm", dimension: "claim:recurringPattern", window: .recurrence(rule: "weekly/1"), formation: .behavioralInference, form: .independentEventSet, display: "周末更常跑步")

        // 四周完整可比 + 反例已查
        let fourWeeks = (0..<8).map { ref("run-\($0)", at: day($0 * 4)) }
        let mature = snapshot(refs: fourWeeks, coverage: 1.0, search: .searchedNoneFound, template: .weeklyRhythm, completePeriods: 4)
        expect(HoloKnowledgeAdmission.assess(semantic: pattern, evidence: mature, authorizedSourceDomains: all) == .worthConfirming,
               "S08 四周完整数据成熟 → 值得确认")

        // 跨度不够
        let twoWeeks = (0..<8).map { ref("run-\($0)", at: day($0)) }
        expect(HoloKnowledgeAdmission.assess(semantic: pattern, evidence: snapshot(refs: twoWeeks, coverage: 1.0, search: .searchedNoneFound, template: .weeklyRhythm), authorizedSourceDomains: all) == .internalOnly(reason: .insufficientSpan),
               "跨度不足停留后台")

        // 没搜反例
        expect(HoloKnowledgeAdmission.assess(semantic: pattern, evidence: snapshot(refs: fourWeeks, coverage: 1.0, search: .notSearched, template: .weeklyRhythm), authorizedSourceDomains: all) == .internalOnly(reason: .counterexampleSearchIncomplete),
               "反例未查不晋级")

        // 反例存在
        expect(HoloKnowledgeAdmission.assess(semantic: pattern, evidence: snapshot(refs: fourWeeks, counter: [ref("c", at: day(10))], coverage: 1.0, search: .searchedFound, template: .weeklyRhythm), authorizedSourceDomains: all) == .internalOnly(reason: .counterexampleFound),
               "S10/S48 反例存在不晋级")

        // S43 无模板的跨域并发 → 内部
        let assoc = semantic(object: "slot-x", relation: "co-occurs", dimension: "claim:association", formation: .behavioralInference, form: .multiSourceSemanticRelation, display: "两个变化同日发生")
        expect(HoloKnowledgeAdmission.assess(semantic: assoc, evidence: snapshot(refs: fourWeeks, coverage: 1.0, search: .searchedNoneFound, template: nil), authorizedSourceDomains: all) == .internalOnly(reason: .templateNotRegistered),
               "S43/U05 未登记统计模板不上线")

        // S48 跨域关联需 holdout
        let crossRefs = (0..<8).map { ref("x-\($0)", domain: $0 % 2 == 0 ? .habit : .finance, at: day($0 * 5)) }
        let noHoldout = snapshot(refs: crossRefs, coverage: 1.0, search: .searchedNoneFound, template: .openConditionalAssociation)
        expect(HoloKnowledgeAdmission.assess(semantic: assoc, evidence: noHoldout, authorizedSourceDomains: all) == .internalOnly(reason: .holdoutNotValidated),
               "S48 原发现样本不当验证样本")
        var withHoldout = noHoldout
        withHoldout.holdoutValidatedPeriods = 1
        withHoldout.completePeriods = 2
        expect(HoloKnowledgeAdmission.assess(semantic: assoc, evidence: withHoldout, authorizedSourceDomains: all) == .worthConfirming,
               "S44 完整验证周期后可进入值得确认（仍只表达关联）")

        // 医疗禁推的模型解释不保存
        var medical = pattern
        medical.prohibitedInferences = ["medical:diagnosis"]
        expect(HoloKnowledgeAdmission.assess(semantic: medical, evidence: mature, authorizedSourceDomains: all) == .reject(reason: .prohibitedInference),
               "S11/S15 不升级为诊断")
    }

    // MARK: C01 / C02 确认绑定语义指纹

    static func testResolverConfirmBinding() {
        let fourWeeks = (0..<8).map { ref("run-\($0)", at: day($0 * 4)) }
        let evidence = snapshot(refs: fourWeeks, coverage: 1.0, search: .searchedNoneFound, template: .weeklyRhythm, completePeriods: 4)
        let v1 = semantic(object: "slot-run", relation: "weekly-rhythm", dimension: "claim:recurringPattern", window: .recurrence(rule: "weekly/1"), formation: .behavioralInference, form: .independentEventSet, display: "周末更常跑步")
        let rev1 = revision(v1, evidence: evidence, at: day(30))
        let prop = rev1.propositionID

        // 未确认：值得确认，不可用于回答
        let pending = resolve([rev1], [])!
        expect(pending.decision == .worthConfirming, "成熟归纳确认前只是值得确认")
        expect(!pending.decision.isUsableForAnswering, "确认前不跨会话作为个人规律使用")

        // 确认 v1
        let confirm = op("c1", .confirm, prop: prop, digest: rev1.semanticDigest, payload: .confirmation(semanticDigest: rev1.semanticDigest, evidenceSnapshotID: evidence.id), at: day(31))
        let confirmed = resolve([rev1], [confirm])!
        expect(confirmed.decision == .confirmedValid, "C01 确认后已记住")
        expect(confirmed.confirmedSemanticDigest == rev1.semanticDigest, "确认绑定语义指纹")
        expect(confirmed.allowedUses.contains(.qualifiedAdvice), "已确认规律可提供带限定建议")

        // C02 同语义新证据：快照刷新，确认不丢
        let refreshed = op("es1", .evidenceSnapshot, prop: prop, digest: rev1.semanticDigest, payload: .evidenceSnapshot(snapshot(refs: fourWeeks + [ref("run-9", at: day(40))], coverage: 1.0, search: .searchedNoneFound, template: .weeklyRhythm)), at: day(41))
        let afterRefresh = resolve([rev1], [confirm, refreshed])!
        expect(afterRefresh.decision == .confirmedValid, "C02 普通证据刷新不要求重确认")
        expect(afterRefresh.latestEvidenceSnapshot?.independentEventCount == 9, "最新证据快照生效")

        // C01 含义不同的 v2：不继承确认
        let v2 = semantic(object: "slot-run", relation: "weekly-rhythm", dimension: "claim:recurringPattern", window: .ongoing, formation: .behavioralInference, form: .independentEventSet, display: "一直都跑步")
        let rev2 = revision(v2, evidence: evidence, at: day(45))
        let withV2 = resolve([rev1, rev2], [confirm])!
        expect(withV2.confirmedSemanticDigest == rev1.semanticDigest, "旧确认仍只绑 v1")
        expect(withV2.currentRevision?.semanticRevisionID == rev1.semanticRevisionID, "当前权威仍是 v1")
        expect(withV2.proposedRevision?.semanticRevisionID == rev2.semanticRevisionID, "v2 作为待确认新建议并存")
        expect(withV2.decision == .confirmedValid, "已确认有效版本继续可用，新版本不自动替代")
    }

    // MARK: C04 / C06 / C12 控制代数

    static func testResolverControlAlgebra() {
        let userRef = ref("say", domain: .conversation, at: t0, kind: .explicitUserStatement)
        let rev = revision(semantic(), evidence: snapshot(refs: [userRef]), at: day(1))
        let prop = rev.propositionID
        expect(resolve([rev], [])!.decision == .remembered, "直接陈述直接记住")

        // C04 不准确只阻断该语义
        let inaccurate = op("i1", .markInaccurate, prop: prop, digest: rev.semanticDigest, payload: .inaccurate(reason: nil, scope: .understanding), at: day(2))
        expect(resolve([rev], [inaccurate])!.decision == .inactive, "不准确 → 不当作当前确定知识")

        // 纠正后的新修订不受旧否定影响（不封禁整个主题）
        let corrected = revision(semantic(polarity: false, formation: .userCorrection, display: "其实不太喜欢阅读"), evidence: snapshot(refs: [ref("say2", domain: .conversation, at: day(3), kind: .explicitUserStatement)]), at: day(3))
        let afterCorrection = resolve([rev, corrected], [inaccurate])!
        expect(afterCorrection.decision == .remembered, "C04 不准确不封禁整个主题：用户纠正成为新权威")
        expect(afterCorrection.currentRevision?.semanticDigest == corrected.semanticDigest, "当前权威是用户纠正版本")

        // 停用 / 恢复：恢复必须见过停用
        let disable = op("d1", .disable, prop: prop, at: day(4))
        expect(resolve([rev], [disable])!.decision == .inactive, "停用 → 停止使用保留历史")
        let blindRestore = op("r1", .restore, prop: prop, priors: [], at: day(5))
        expect(resolve([rev], [disable, blindRestore])!.decision == .inactive, "C06 未见过限制的恢复不能解除停用（限制优先）")
        let seenRestore = op("r2", .restore, prop: prop, priors: ["d1"], at: day(5))
        expect(resolve([rev], [disable, seenRestore])!.decision == .remembered, "见过全部限制的恢复生效")

        // C06 确认与限制并发：确认没见过限制 → 不生效
        let patternRefs = (0..<8).map { ref("p-\($0)", at: day($0 * 4)) }
        let patRev = revision(semantic(object: "slot-p", dimension: "claim:recurringPattern", window: .recurrence(rule: "weekly/1"), formation: .behavioralInference, form: .independentEventSet, display: "规律"), evidence: snapshot(refs: patternRefs, coverage: 1, search: .searchedNoneFound, template: .weeklyRhythm, completePeriods: 4), at: day(30))
        let pDisable = op("pd", .disable, prop: patRev.propositionID, at: day(31))
        let pConfirmBlind = op("pc", .confirm, prop: patRev.propositionID, digest: patRev.semanticDigest, priors: [], at: day(31))
        expect(resolve([patRev], [pDisable, pConfirmBlind])!.decision == .inactive, "C06 并发：限制优先，旧确认不静默解除未见限制")

        // 遗忘：正文清除，最小阻断
        let forget = op("f1", .forget, prop: prop, at: day(6))
        let forgotten = resolve([rev], [forget])!
        expect(forgotten.decision == .inactive && forgotten.displayText.isEmpty, "C04 遗忘涵盖正文，仅留阻断")
        expect(forgotten.restrictingOperationIDs.contains("f1"), "遗忘是生效中的限制")

        // 暂不处理不是否定
        let defer_ = op("df", .deferCooldown, prop: patRev.propositionID, digest: patRev.semanticDigest, payload: .cooldown(until: day(61)), at: day(31))
        let deferred = resolve([patRev], [defer_])!
        expect(deferred.decision == .worthConfirming, "C04 暂不处理不改变事实状态")
        expect(deferred.cooldownUntil == day(61), "冷却截止可查（推荐区据此过滤）")

        // C12 撤销只对最近一次操作生效
        let undoLatest = op("u1", .undo, prop: prop, payload: .undo(targetOperationID: "d1"), at: day(7))
        expect(resolve([rev], [disable, undoLatest])!.decision == .remembered, "撤销最近一次停用")
        let undoStale = op("u2", .undo, prop: prop, payload: .undo(targetOperationID: "d1"), at: day(8))
        expect(resolve([rev], [disable, op("d2", .disable, prop: prop, at: day(7)), undoStale])!.decision == .inactive, "撤销目标不是最近一次用户操作时无效")
    }

    // MARK: C03 / S20 / M04 来源与基线

    static func testResolverSourceAndBaseline() {
        let userRef = ref("say", domain: .conversation, at: day(10), kind: .explicitUserStatement)
        let stated = revision(semantic(), evidence: snapshot(refs: [userRef]), at: day(10))
        expect(resolve([stated], [], source: .deleted)!.decision == .remembered, "C03 用户亲口补充不因原行为来源删除而抹掉")

        let linked = revision(semantic(formation: .sourceLinked, form: .explicitSemanticFact, display: "预算 3000"), evidence: snapshot(refs: [ref("b", domain: .finance, at: day(10))]), at: day(10))
        expect(resolve([linked], [], source: .verified)!.decision == .remembered, "来源关联存在时可用")
        expect(resolve([linked], [], source: .deleted)!.decision == .inactive, "S20 来源删除 → 相应证据退出")
        expect(resolve([linked], [], source: .excluded)!.decision == .inactive, "S40 AI 排除优先")
        expect(resolve([linked], [], source: .unknown)!.decision == .inactive, "来源核验不以 Unknown 放行")
        expect(resolve([linked], [], source: .revised)!.decision == .remembered, "来源编辑触发重核但不立即退出")

        // M04 清空基线：全部证据早于基线 → 不当新证据
        expect(resolve([stated], [], baseline: day(20))!.decision == .inactive, "M04 基线前证据不复活")
        expect(resolve([stated], [], baseline: day(5))!.decision == .remembered, "基线后证据正常")

        // 当前状态类过期
        let phase = revision(semantic(dimension: "facet:state", window: .absolute(from: day(0), to: day(20)), formation: .sourceLinked, form: .explicitSemanticFact, display: "两周不宜跑步"), evidence: snapshot(refs: [ref("h", domain: .health, at: day(0))]), at: day(0))
        expect(resolve([phase], [], now: day(10))!.decision == .remembered, "S13 时间限制期内可用")
        expect(resolve([phase], [], now: day(30))!.decision == .inactive, "S13 过期即不作当前事实")
        let preference = revision(semantic(window: .ongoing), evidence: snapshot(refs: [userRef]), at: day(0))
        expect(resolve([preference], [], now: day(400))!.decision == .remembered, "偏好持续有效直至修改")
    }

    // MARK: M05/M06 Codable 容错

    static func testOperationPayloadCodable() {
        let encoder = CoreDataHoloMemoryRepository.knowledgeEncoder()
        let decoder = CoreDataHoloMemoryRepository.knowledgeDecoder()
        let snapshot = snapshot(refs: [ref("1", at: t0)])
        let payloads: [HoloKnowledgeOperationPayload] = [
            .none,
            .confirmation(semanticDigest: "sd-1", evidenceSnapshotID: "es-1"),
            .correction(newRevisionID: "rev-2", statement: "新说法"),
            .inaccurate(reason: "x", scope: .evidence),
            .narrowing(validTo: t0),
            .cooldown(until: t0),
            .undo(targetOperationID: "op-9"),
            .evidenceSnapshot(snapshot),
            .aliasImport(legacyRecordID: "legacy", legacyUserDecision: "confirmed"),
            .migrationReceipt(HoloKnowledgeMigrationReceipt(processingKey: "k", legacyRecordID: "l", legacyRecordVersion: 1, policyVersion: 1, partition: .normal, status: .committed, completedAt: t0)),
            .promptRecord(entry: "discovery", semanticDigest: "sd", outcome: "saved"),
            .sourceInvalidation(sourceRefs: ["thought:x"], status: "deleted"),
        ]
        for payload in payloads {
            let operation = op("id", .confirm, prop: "p", payload: payload, at: t0)
            let data = try! encoder.encode(operation)
            let decoded = try! decoder.decode(HoloKnowledgeOperation.self, from: data)
            expect(decoded == operation, "操作载荷往返一致: \(payload)")
        }
        // 未知载荷种类（09-R06 升级）：不崩整批；保留 kind 诊断 + 保守限制，
        // 不再静默降 none（none 会让未知控制被当已知放行）。
        let unknown = #"{"kind":"futureKind","foo":1}"#.data(using: .utf8)!
        let decodedUnknown = try! decoder.decode(HoloKnowledgeOperationPayload.self, from: unknown)
        expect(decodedUnknown == .unknownPreserved(kind: "futureKind"), "M06 未知载荷保留诊断不降级")
        let unknownOp = op("u9", .unknownPreserved("futureKind"), prop: "p", at: t0)
        expect(unknownOp.kind.isUsageRestricting, "M06 未知种类按限制保守处理")

        // 窗口规则往返
        let rules: [HoloKnowledgeApplicability.WindowRule] = [.ongoing, .absolute(from: t0, to: nil), .rolling(days: 30), .recurrence(rule: "weekly/1/wd2")]
        for rule in rules {
            let data = try! encoder.encode(rule)
            expect(try! decoder.decode(HoloKnowledgeApplicability.WindowRule.self, from: data) == rule, "窗口规则往返: \(rule)")
        }
        // 未知来源状态字串
        let status = try! decoder.decode(HoloKnowledgeSourceStatus.self, from: "\"mystery\"".data(using: .utf8)!)
        expect(status == .unknown, "未知来源状态归 unknown（不放行）")
    }

    // MARK: S14 / M13 分区

    static func testPartitionPolicy() {
        expect(HoloKnowledgePartitionPolicy.partition(sensitivity: .normal, domains: [.habit], evidence: [ref("a", at: t0)]) == .normal, "普通知识普通分区")
        expect(HoloKnowledgePartitionPolicy.partition(sensitivity: .normal, domains: [.habit, .health], evidence: []) == .sensitiveLocal, "S14 含健康域 → 本机分区")
        expect(HoloKnowledgePartitionPolicy.partition(sensitivity: .normal, domains: [.finance], evidence: [ref("h", domain: .health, at: t0)]) == .sensitiveLocal, "S14 健康证据派生取最高敏感级别")
        expect(HoloKnowledgePartitionPolicy.partition(sensitivity: .sensitive, domains: [.thought], evidence: []) == .sensitiveLocal, "敏感内容本机")
        expect(HoloKnowledgePartition.stricter(.normal, .sensitiveLocal) == .sensitiveLocal, "分区合并取更严")
    }

    // MARK: S20 / D11 来源失效操作推导

    static func testPersistedSourceStatus() {
        let prop = "p"
        expect(HoloKnowledgeResolver.persistedSourceStatus(operations: []) == .verified, "无失效记录 = 已核验")
        let deleted = op("s1", .sourceInvalidation, prop: prop, payload: .sourceInvalidation(sourceRefs: ["thought:a"], status: "deleted"), at: day(1))
        expect(HoloKnowledgeResolver.persistedSourceStatus(operations: [deleted]) == .deleted, "删除来源命中")
        let refresh = op("es", .evidenceSnapshot, prop: prop, payload: .evidenceSnapshot(snapshot(refs: [ref("a", domain: .thought, at: day(2))])), at: day(2))
        // 09-R11：晚到的证据快照没有核验过「用户此刻没有删除」——不得清除 deleted。
        expect(HoloKnowledgeResolver.persistedSourceStatus(operations: [deleted, refresh]) == .deleted, "R11 晚到的旧快照不解除删除")
        // 重新读取能自证的软失效（revised）可被更晚快照清除。
        let revisedOp = op("s2", .sourceInvalidation, prop: prop, payload: .sourceInvalidation(sourceRefs: ["thought:b"], status: "revised"), at: day(1))
        let refreshB = op("es2", .evidenceSnapshot, prop: prop, payload: .evidenceSnapshot(snapshot(refs: [ref("b", domain: .thought, at: day(2))])), at: day(2))
        expect(HoloKnowledgeResolver.persistedSourceStatus(operations: [revisedOp, refreshB]) == .verified, "更晚快照可清除 revised")
        let conservative = op("s2", .sourceInvalidation, prop: prop, payload: .sourceInvalidation(sourceRefs: [], status: "unknown"), at: day(3))
        expect(HoloKnowledgeResolver.persistedSourceStatus(operations: [conservative]) == .unknown, "命题级保守失效生效")
        let verifiedReceipt = op("s3", .sourceInvalidation, prop: prop, payload: .sourceInvalidation(sourceRefs: [], status: "verified"), at: day(4))
        expect(HoloKnowledgeResolver.persistedSourceStatus(operations: [conservative, verifiedReceipt]) == .verified, "复核回执清除命题级失效")
        let mixed = [
            op("m1", .sourceInvalidation, prop: prop, payload: .sourceInvalidation(sourceRefs: ["a"], status: "revised"), at: day(1)),
            op("m2", .sourceInvalidation, prop: prop, payload: .sourceInvalidation(sourceRefs: ["b"], status: "excluded"), at: day(1)),
        ]
        expect(HoloKnowledgeResolver.persistedSourceStatus(operations: mixed) == .excluded, "多来源取最严重")
    }
}
