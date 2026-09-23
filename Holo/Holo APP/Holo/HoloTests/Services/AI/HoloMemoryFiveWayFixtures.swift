import Foundation

#if HOLO_XCTEST_BRIDGE
@testable import Holo
#endif

//
//  HoloMemoryFiveWayFixtures.swift
//  Holo
//
//  五路决策纯逻辑 fixtures（记忆低确认成本方案 P0 冻结评测输入，方案 §16.1/§17 P0）。
//
//  每条 fixture 同时锁定三件事：输入记录、期望的权威性/核验/影响推导、期望的五路结果。
//  derivation 如实标注「今天能否从现有字段稳定推导」——requiresContractProof 的条目
//  是方案 §13.1 的灰度门禁项：P2/P4 必须先过冻结 fixtures 评测，不足则走 Prompt vNext，
//  不得用自由文本猜测补齐。
//
//  本文件是纯数据，不含可执行启动器；由 HoloMemoryDecisionContractStandaloneTests 与 P2 策略测试消费。
//

struct HoloMemoryFiveWayFixture {
    enum DerivationStatus: String, Sendable {
        /// 现有字段（evidence kind / epistemicStatus / temporal / sensitivity / 反证等）足以稳定推导。
        case derivableToday
        /// 现有契约缺少稳定信号，P2/P4 需先证明契约能力（方案 §13.1 门禁）。
        case requiresContractProof
    }

    let scenarioID: String
    /// 场景说明（引用方案小节）。
    let note: String
    let record: HoloMemoryRecord
    let expectedRoute: HoloMemoryFiveWayRoute
    /// nil 表示权威性判别依赖尚未证明的契约能力。
    let expectedAuthority: HoloMemorySourceAuthority?
    let expectedVerdict: HoloMemoryEvidenceVerdict?
    let expectedImpact: HoloMemoryDecisionImpactLevel?
    let derivation: DerivationStatus
}

enum HoloMemoryFiveWayFixtures {
    /// 冻结时间锚：所有 fixture 用同一时刻构造，保证可复现。
    static let anchorNow = Date(timeIntervalSince1970: 1_757_980_800) // 2026-09-16 00:00 UTC

    static let all: [HoloMemoryFiveWayFixture] = [
        mtx01FinanceStructuredFact,
        mtx02HealthStructuredStat,
        mtx03DeclaredPreference,
        mtx04ExplicitMemoryRequest,
        mtx05SensitiveFreeTextNoAuthorization,
        mtx06ThirdPartySensitive,
        mtx07SingleOccurrence,
        mtx08FirstCrossDomainCorrelation,
        mtx09CrossDomainNoCommonWindow,
        mtx10HighImpactMedicalInference,
        mtx11HighImpactQualifiedInference,
        mtx12RepeatedEvidenceLow,
        mtx13RepeatedEvidenceMedium,
        mtx14ConflictingDeclaredStatements,
        mtx15UnsupportedOverreach,
        mtx16UnreviewedCandidate,
        adv01HypotheticalStatement,
        adv02QuotedThirdParty,
        adv03TemporaryChoiceWithoutExpiry,
        adv04PastStateAsPresent,
        adv05StructuredHighImpact,
    ]

    // MARK: - 构造助手

    /// 领域结构化记忆（evidence = aggregateSnapshot，有界窗口）。
    private static func makeStructuredRecord(
        id: String,
        domain: HoloMemoryDomain,
        claimKind: HoloMemoryClaimKind,
        persistenceClass: HoloMemoryPersistenceClass,
        sensitivity: HoloMemorySensitivity = .normal,
        state: HoloMemoryState = .candidate,
        summary: String,
        lineageKey: String,
        windowDays: Int = 30,
        sampleCount: Int = 14,
        now: Date = anchorNow,
        prohibitedInferences: [String] = []
    ) throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(type: anchorType(for: domain), value: lineageKey)
        let evidence = HoloMemoryEvidenceRef(
            id: "\(id)-evidence",
            kind: .aggregateSnapshot,
            sourceDomain: domain,
            lineageKey: lineageKey,
            revisionDigest: "rev-1",
            observedAt: now,
            validFrom: now.addingTimeInterval(Double(-windowDays) * 86_400),
            validTo: now,
            aggregateDefinition: "window=\(windowDays)d",
            sampleCount: sampleCount,
            summary: summary
        )
        let stableID = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            claimKind: claimKind,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: stableID,
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: claimKind,
            persistenceClass: persistenceClass,
            displaySummary: summary,
            aiUseSummary: summary,
            prohibitedInferences: prohibitedInferences,
            evidenceRefs: [evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            validFrom: evidence.validFrom,
            validTo: evidence.validTo,
            lastSupportedAt: now,
            confidenceScore: 0.8,
            freshnessScore: 1,
            scoringVersion: 1,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: state,
            sensitivity: sensitivity,
            userDecision: .none,
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now
        )
    }

    /// 个人情境记录（宿主记录形态仿照 HoloPersonalContextExtractor.makeRecord）。
    private static func makeContextRecord(
        id: String,
        statement: String,
        relationText: String,
        claimKind: HoloMemoryClaimKind,
        epistemicStatus: HoloContextEpistemicStatus,
        admission: HoloContextAdmissionLevel,
        sensitivity: HoloMemorySensitivity = .normal,
        state: HoloMemoryState = .candidate,
        subjects: [HoloContextPartyRef] = [],
        objects: [HoloContextPartyRef] = [],
        temporal: HoloContextTemporalV1? = nil,
        counterEvidence: [HoloMemoryEvidenceRef] = [],
        evidenceKind: HoloMemoryEvidenceKind = .explicitUserStatement,
        prohibitedInferences: [String] = [],
        now: Date = anchorNow
    ) throws -> HoloMemoryRecord {
        let contextID = "fixture-\(id)"
        let payload = HoloPersonalContextPayloadV1(
            contextID: contextID,
            statement: statement,
            subjects: subjects,
            objects: objects,
            relationText: relationText,
            epistemicStatus: epistemicStatus,
            applicability: HoloContextApplicabilityV1(),
            temporal: temporal,
            basis: [
                HoloContextBasisRef(
                    sourceID: "\(id)-source",
                    quote: statement,
                    sourceRevision: "rev-1"
                )
            ],
            openQuestions: [],
            admission: HoloContextAdmissionV1(
                level: admission,
                policyVersion: 1,
                decidedAt: now
            )
        )
        let anchor = try HoloMemoryAnchorRef(type: .conversation, value: payload.contextAnchorValue)
        let evidence = HoloMemoryEvidenceRef(
            id: "\(id)-evidence",
            kind: evidenceKind,
            sourceDomain: .conversation,
            lineageKey: "\(id)-lineage",
            revisionDigest: "rev-1",
            observedAt: now,
            summary: statement
        )
        let stableID = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .conversation,
            sourceDomains: [.conversation],
            claimKind: claimKind,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: stableID,
            scope: .domain,
            primaryDomain: .conversation,
            sourceDomains: [.conversation],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: claimKind,
            persistenceClass: .durable,
            displaySummary: statement,
            aiUseSummary: statement,
            prohibitedInferences: prohibitedInferences,
            evidenceRefs: [evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: counterEvidence,
            lastSupportedAt: now,
            confidenceScore: 0.6,
            freshnessScore: 0.8,
            scoringVersion: 1,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: state,
            sensitivity: sensitivity,
            userDecision: .none,
            createdAt: now.addingTimeInterval(-3_600),
            updatedAt: now,
            personalContext: HoloPersonalContextPayloadEnvelope(v1: payload)
        )
    }

    private static func anchorType(for domain: HoloMemoryDomain) -> HoloMemoryAnchorType {
        switch domain {
        case .finance: return .financeCategory
        case .thought: return .thoughtTopic
        case .health: return .healthMetric
        case .habit: return .habit
        case .task: return .task
        case .goal: return .goal
        case .conversation: return .conversation
        case .profile: return .profile
        }
    }

    private static func day(_ offset: Double, from now: Date = anchorNow) -> Date {
        now.addingTimeInterval(offset * 86_400)
    }

    // MARK: - 主决策矩阵 fixtures（§7.1）

    /// §9.1 财务客观状态：近 30 天餐饮支出较前一周期上升（结构化聚合）。
    static let mtx01FinanceStructuredFact: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-01",
        note: "结构化有界财务事实，supported 低影响 → factEligible（§9.1）",
        record: (try? makeStructuredRecord(
            id: "mtx01",
            domain: .finance,
            claimKind: .observedFact,
            persistenceClass: .phase,
            summary: "近 30 天餐饮支出较前一周期上升",
            lineageKey: "finance-dining-30d",
            windowDays: 30,
            sampleCount: 30
        ))!,
        expectedRoute: .factEligible,
        expectedAuthority: .structuredObservation,
        expectedVerdict: .supported,
        expectedImpact: .low,
        derivation: .derivableToday
    )

    /// §9.2 健康客观统计：最近 14 天平均睡眠时长下降（HealthKit 聚合，有界窗口）。
    static let mtx02HealthStructuredStat: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-02",
        note: "健康结构化统计保留时间范围，supported 低影响 → factEligible；禁止扩写成诊断（§9.2）",
        record: (try? makeStructuredRecord(
            id: "mtx02",
            domain: .health,
            claimKind: .observedFact,
            persistenceClass: .currentState,
            summary: "最近 14 天平均睡眠时长较此前下降",
            lineageKey: "health-sleep-14d",
            windowDays: 14,
            sampleCount: 14,
            prohibitedInferences: ["medicalDiagnosis"]
        ))!,
        expectedRoute: .factEligible,
        expectedAuthority: .structuredObservation,
        expectedVerdict: .supported,
        expectedImpact: .low,
        derivation: .derivableToday
    )

    /// §9.5 明确偏好：用户明确说「以后周五不要给我安排早会」。
    static let mtx03DeclaredPreference: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-03",
        note: "用户明确陈述且断言门禁通过 → factEligible，不再二次确认（§4.2/§9.5）",
        record: (try? makeContextRecord(
            id: "mtx03",
            statement: "以后周五不要给我安排早会",
            relationText: "周五早晨不安排会议",
            claimKind: .explicitPreference,
            epistemicStatus: .declared,
            admission: .adviceEligible
        ))!,
        expectedRoute: .factEligible,
        expectedAuthority: .explicitUserStatement,
        expectedVerdict: .supported,
        expectedImpact: .medium,
        derivation: .derivableToday
    )

    /// §4.2 明确记忆请求：「请记住我不吃香菜」。现有契约无「明确要求记住」信号 → §13.1 门禁项。
    static let mtx04ExplicitMemoryRequest: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-04",
        note: "明确记忆请求 → factEligible；但 explicitMemoryRequest 信号现有字段无法稳定判别，须先过契约评测（§6.1/§13.1）",
        record: (try? makeContextRecord(
            id: "mtx04",
            statement: "请记住我不吃香菜",
            relationText: "不吃香菜",
            claimKind: .explicitPreference,
            epistemicStatus: .declared,
            admission: .adviceEligible
        ))!,
        expectedRoute: .factEligible,
        expectedAuthority: .explicitMemoryRequest,
        expectedVerdict: .supported,
        expectedImpact: .low,
        derivation: .requiresContractProof
    )

    /// §4.2/ADR-5 敏感自由文本无持久化授权：普通聊天中提到的敏感内容不得形成长期派生记忆。
    static let mtx05SensitiveFreeTextNoAuthorization: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-05",
        note: "敏感用户陈述但无派生记忆持久化授权 → discard（不写派生记忆，原始来源按自身权限用）（§7.1 第三行）",
        record: (try? makeContextRecord(
            id: "mtx05",
            statement: "最近在服用抗焦虑药物",
            relationText: "服用药物",
            claimKind: .observedFact,
            epistemicStatus: .declared,
            admission: .confirmationOnly,
            sensitivity: .sensitive
        ))!,
        expectedRoute: .discard,
        expectedAuthority: .explicitUserStatement,
        // 首版保守口径：confirmationOnly 投影为 unreviewed（不区分敏感降级与未核验）；
        // 影响按域判定（健康语义判别缺信号）。路由不变（持久化门先于核验分支）。
        expectedVerdict: .unreviewed,
        expectedImpact: .medium,
        derivation: .derivableToday
    )

    /// §7.2 第三方敏感信息：关于父亲的健康约束，默认不得形成长期记忆。
    static let mtx06ThirdPartySensitive: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-06",
        note: "第三方敏感信息默认不形成长期记忆 → discard（除非明确要求+最小范围）（§7.2）",
        record: (try? makeContextRecord(
            id: "mtx06",
            statement: "父亲需要低盐饮食",
            relationText: "需要低盐饮食",
            claimKind: .observedFact,
            epistemicStatus: .declared,
            admission: .confirmationOnly,
            sensitivity: .sensitive,
            subjects: [HoloContextPartyRef(ref: "family-father", label: "父亲", scope: .person)]
        ))!,
        expectedRoute: .discard,
        expectedAuthority: .explicitUserStatement,
        // 首版保守口径：confirmationOnly → unreviewed（投影不区分降级原因）。
        expectedVerdict: .unreviewed,
        expectedImpact: .medium,
        derivation: .derivableToday
    )

    /// §9.4 单次现象：本周第一次连续三天早起，证据不足等待补证。
    static let mtx07SingleOccurrence: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-07",
        note: "单次现象 insufficient → observeOnly，不问「你是不是早起型的人」（§9.4）",
        record: (try? makeStructuredRecord(
            id: "mtx07",
            domain: .habit,
            claimKind: .observedFact,
            persistenceClass: .currentState,
            summary: "本周第一次连续三天早起",
            lineageKey: "habit-early-rise-week",
            windowDays: 7,
            sampleCount: 3
        ))!,
        expectedRoute: .observeOnly,
        expectedAuthority: .structuredObservation,
        expectedVerdict: .insufficient,
        expectedImpact: .low,
        derivation: .derivableToday
    )

    /// §9.3 首次跨域相关：睡眠偏少与外卖支出较高同期出现，独立来源共同窗口成立。
    static let mtx08FirstCrossDomainCorrelation: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-08",
        note: "首次跨域相关 qualified 低影响 → qualifiedAdvice，限定表达不询问（§9.3/§7.2）",
        record: (try? makeCrossDomainRecord(
            id: "mtx08",
            summary: "睡眠偏少的几天与外卖支出较高曾同期出现",
            commonWindow: true,
            claimKind: .association,
            prohibitedInferences: ["causalClaim"]
        ))!,
        expectedRoute: .qualifiedAdvice,
        expectedAuthority: .modelInference,
        expectedVerdict: .qualified,
        expectedImpact: .low,
        derivation: .derivableToday
    )

    /// §7.2 首次跨域：没有共同时间窗/独立 lineage → discard。
    static let mtx09CrossDomainNoCommonWindow: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-09",
        note: "跨域无共同时间窗与独立 lineage → discard（§7.2 首次跨域末行）",
        record: (try? makeCrossDomainRecord(
            id: "mtx09",
            summary: "睡眠与支出存在关联",
            commonWindow: false,
            claimKind: .association,
            prohibitedInferences: []
        ))!,
        expectedRoute: .discard,
        expectedAuthority: .modelInference,
        expectedVerdict: .unsupported,
        expectedImpact: .low,
        derivation: .derivableToday
    )

    /// §9.7 高影响无支持推断：从情绪想法推断焦虑症——系统不应生成，不能靠点击转正。
    static let mtx10HighImpactMedicalInference: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-10",
        note: "AI 推断疾病/心理/医疗因果 → 直接 discard，不能通过确认卡洗白（§7.2/§9.7）",
        record: (try? makeContextRecord(
            id: "mtx10",
            statement: "从近期想法看可能存在焦虑倾向",
            relationText: "可能存在焦虑",
            claimKind: .hypothesis,
            epistemicStatus: .inferred,
            admission: .forbidden,
            sensitivity: .highImpact,
            prohibitedInferences: ["medicalDiagnosis", "psychologicalDiagnosis"]
        ))!,
        expectedRoute: .discard,
        expectedAuthority: .modelInference,
        expectedVerdict: .unsupported,
        expectedImpact: .high,
        derivation: .derivableToday
    )

    /// §7.1 矩阵：AI 推断 qualified 高影响 → askWhenRelevant，未回答前 blocked。
    static let mtx11HighImpactQualifiedInference: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-11",
        note: "高影响 qualified 推断 → askWhenRelevant（只在相关时问一次，回答前不作为事实）（§7.1）",
        record: (try? makeCrossDomainRecord(
            id: "mtx11",
            summary: "深夜工作时段与次日血压读数偏高曾同期出现",
            commonWindow: true,
            claimKind: .association,
            prohibitedInferences: ["medicalDiagnosis", "causalClaim"]
        ))!,
        expectedRoute: .askWhenRelevant,
        expectedAuthority: .modelInference,
        expectedVerdict: .qualified,
        expectedImpact: .high,
        derivation: .derivableToday
    )

    /// §7.1 矩阵：独立重复证据 supported 低影响 → factEligible。
    static let mtx12RepeatedEvidenceLow: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-12",
        note: "多窗口独立 lineage 一致 → repeatedIndependentEvidence 低影响 → factEligible（§7.1）",
        record: (try? makeRepeatedEvidenceRecord(
            id: "mtx12",
            domain: .finance,
            summary: "连续多周工作日晚间外卖支出稳定",
            claimKind: .recurringPattern,
            windows: [(-60, -31), (-30, -1)]
        ))!,
        expectedRoute: .factEligible,
        expectedAuthority: .repeatedIndependentEvidence,
        expectedVerdict: .supported,
        expectedImpact: .low,
        derivation: .derivableToday
    )

    /// §7.1 矩阵：独立重复证据 supported 中影响 → qualifiedAdvice（时间偏好/阶段状态）。
    static let mtx13RepeatedEvidenceMedium: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-13",
        note: "重复独立证据但会明显改变规划 → qualifiedAdvice，不得当确定事实（§7.1）",
        record: (try? makeRepeatedEvidenceRecord(
            id: "mtx13",
            domain: .habit,
            summary: "连续多周在晚间完成主要运动安排",
            claimKind: .recurringPattern,
            windows: [(-56, -29), (-28, -1)]
        ))!,
        expectedRoute: .qualifiedAdvice,
        expectedAuthority: .repeatedIndependentEvidence,
        expectedVerdict: .supported,
        expectedImpact: .medium,
        derivation: .derivableToday
    )

    /// §9.6 冲突影响当前计划：旧「周日陪父亲复诊」vs 新「这个月周日空出来」。
    static let mtx14ConflictingDeclaredStatements: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-14",
        note: "明确陈述间存在未解冲突且影响规划 → askWhenRelevant；无相关场景时不问（§6.4/§9.6）",
        record: (try? makeContextRecord(
            id: "mtx14",
            statement: "这个月开始周日上午空出来了",
            relationText: "周日早晨空闲",
            claimKind: .explicitPreference,
            epistemicStatus: .declared,
            admission: .adviceEligible,
            state: .disputed,
            temporal: HoloContextTemporalV1(
                kind: .event,
                originalExpression: "这个月开始",
                precision: .month,
                validFrom: day(-10)
            ),
            counterEvidence: [
                HoloMemoryEvidenceRef(
                    id: "mtx14-counter",
                    kind: .explicitUserStatement,
                    sourceDomain: .conversation,
                    lineageKey: "fixture-legacy-sunday-clinic",
                    revisionDigest: "rev-1",
                    observedAt: day(-120),
                    summary: "周日上午通常陪父亲复诊"
                )
            ]
        ))!,
        expectedRoute: .askWhenRelevant,
        expectedAuthority: .explicitUserStatement,
        expectedVerdict: .contradicted,
        expectedImpact: .medium,
        derivation: .derivableToday
    )

    /// §6.2 unsupported：单域睡眠统计被扩写成「睡眠下降导致消费增加」的伪因果。
    static let mtx15UnsupportedOverreach: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-15",
        note: "原文不支持的越界/伪因果 → discard（§6.2/§7.1 末行）",
        record: (try? makeStructuredRecord(
            id: "mtx15",
            domain: .health,
            claimKind: .association,
            persistenceClass: .phase,
            summary: "睡眠下降导致消费增加",
            lineageKey: "health-sleep-14d",
            windowDays: 14,
            prohibitedInferences: ["causalClaim"]
        ))!,
        expectedRoute: .discard,
        expectedAuthority: .structuredObservation,
        expectedVerdict: .unsupported,
        expectedImpact: .medium,
        derivation: .derivableToday
    )

    /// §6.2 unreviewed：核验未完成（无 verdict 响应）。
    static let mtx16UnreviewedCandidate: HoloMemoryFiveWayFixture = .init(
        scenarioID: "MTX-16",
        note: "核验未完成 → observeOnly，不使用也不打扰（§6.2/§7.1）",
        record: (try? makeContextRecord(
            id: "mtx16",
            statement: "近期记录显示可能更适合上午安排深度工作",
            relationText: "适合上午深度工作",
            claimKind: .hypothesis,
            epistemicStatus: .inferred,
            admission: .confirmationOnly
        ))!,
        expectedRoute: .observeOnly,
        expectedAuthority: .modelInference,
        expectedVerdict: .unreviewed,
        expectedImpact: .low,
        derivation: .derivableToday
    )

    // MARK: - 对抗 fixtures（§6.1 断言门禁）

    /// §6.1 门禁：假设语气（「如果我换工作…」）不得判为明确用户陈述。
    static let adv01HypotheticalStatement: HoloMemoryFiveWayFixture = .init(
        scenarioID: "ADV-01",
        note: "假设/条件句不得按 explicitUserStatement 永久化 → observeOnly；语气判别信号缺失，属 §13.1 门禁（§6.1）",
        record: (try? makeContextRecord(
            id: "adv01",
            statement: "如果我换工作，通勤时间会变长",
            relationText: "通勤时间变长",
            claimKind: .hypothesis,
            epistemicStatus: .declared,
            admission: .confirmationOnly,
            temporal: HoloContextTemporalV1(
                kind: .conditional,
                originalExpression: "如果换工作",
                triggerText: "换工作"
            )
        ))!,
        expectedRoute: .observeOnly,
        expectedAuthority: nil,
        expectedVerdict: .insufficient,
        expectedImpact: .medium,
        derivation: .requiresContractProof
    )

    /// §6.1 门禁：引用/转述他人（「同事说他不吃香菜」）不得判为用户本人陈述。
    static let adv02QuotedThirdParty: HoloMemoryFiveWayFixture = .init(
        scenarioID: "ADV-02",
        note: "转述他人经历非用户陈述 → discard；引用语气判别信号缺失，属 §13.1 门禁（§6.1）",
        record: (try? makeContextRecord(
            id: "adv02",
            statement: "同事说他不吃香菜",
            relationText: "不吃香菜",
            claimKind: .observedFact,
            epistemicStatus: .declared,
            admission: .confirmationOnly,
            objects: [HoloContextPartyRef(label: "同事", scope: .person)]
        ))!,
        expectedRoute: .discard,
        expectedAuthority: nil,
        expectedVerdict: .unsupported,
        expectedImpact: .low,
        derivation: .requiresContractProof
    )

    /// §6.1 门禁 6：「今晚」临时选择缺少有效期，不得自动推成永久偏好。
    static let adv03TemporaryChoiceWithoutExpiry: HoloMemoryFiveWayFixture = .init(
        scenarioID: "ADV-03",
        note: "临时选择默认最窄范围，不得 durable → observeOnly；temporal 缺 validTo 可判别（§6.1 门禁 6）",
        record: (try? makeContextRecord(
            id: "adv03",
            statement: "今晚不安排任何事项",
            relationText: "今晚不安排",
            claimKind: .explicitPreference,
            epistemicStatus: .declared,
            admission: .adviceEligible,
            temporal: HoloContextTemporalV1(
                kind: .event,
                originalExpression: "今晚",
                precision: .day,
                validFrom: day(0),
                validTo: day(1)
            )
        ))!,
        expectedRoute: .observeOnly,
        expectedAuthority: .explicitUserStatement,
        expectedVerdict: .supported,
        // 首版程序口径：偏好类统一 medium；临时范围由 event 门禁兜底。
        expectedImpact: .medium,
        derivation: .derivableToday
    )

    /// §6.1 门禁 5：描述过去状态（已结束的窗口）被写成当前状态。
    static let adv04PastStateAsPresent: HoloMemoryFiveWayFixture = .init(
        scenarioID: "ADV-04",
        note: "过去状态不得改写成当前状态（temporal validTo 已过）→ discard；时间窗口可判别（§6.1 门禁 5/§6.4）",
        record: (try? makeContextRecord(
            id: "adv04",
            statement: "目前在杭州工作",
            relationText: "在杭州工作",
            claimKind: .observedFact,
            epistemicStatus: .declared,
            admission: .adviceEligible,
            temporal: HoloContextTemporalV1(
                kind: .ongoing,
                originalExpression: "之前在杭州工作",
                precision: .month,
                validFrom: day(-400),
                validTo: day(-90)
            )
        ))!,
        expectedRoute: .discard,
        expectedAuthority: .explicitUserStatement,
        // 时效由独立 isExpired 输入承载（非 unsupported）；影响按首版保守口径（low，
        // 「过去状态」语义无需高影响兜底，路由 discard 不变）。
        expectedVerdict: .supported,
        expectedImpact: .low,
        derivation: .derivableToday
    )

    /// §7.2 健康：结构化高影响事实 → qualifiedAdvice 或领域直查，不让记忆替代专业判断。
    static let adv05StructuredHighImpact: HoloMemoryFiveWayFixture = .init(
        scenarioID: "ADV-05",
        note: "结构化 supported 高影响 → qualifiedAdvice，领域明细实时查询（§7.1/§7.2 健康）",
        record: (try? makeStructuredRecord(
            id: "adv05",
            domain: .health,
            claimKind: .observedFact,
            persistenceClass: .currentState,
            sensitivity: .highImpact,
            summary: "近 14 天服药记录集中在早晨 7-8 点",
            lineageKey: "health-medication-window-14d",
            windowDays: 14,
            sampleCount: 14,
            prohibitedInferences: ["medicalDiagnosis", "medicationAdjustment"]
        ))!,
        expectedRoute: .qualifiedAdvice,
        expectedAuthority: .structuredObservation,
        expectedVerdict: .supported,
        expectedImpact: .high,
        derivation: .derivableToday
    )

    // MARK: - 跨域/重复证据构造

    private static func makeCrossDomainRecord(
        id: String,
        summary: String,
        commonWindow: Bool,
        claimKind: HoloMemoryClaimKind,
        prohibitedInferences: [String],
        now: Date = anchorNow
    ) throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(type: .goal, value: "fixture-\(id)-goal")
        let domains: [HoloMemoryDomain] = [.health, .finance]
        let evidence = domains.enumerated().map { index, domain in
            HoloMemoryEvidenceRef(
                id: "\(id)-evidence-\(domain.rawValue)",
                kind: .aggregateSnapshot,
                sourceDomain: domain,
                lineageKey: "\(id)-lineage-\(domain.rawValue)",
                revisionDigest: "rev-1",
                observedAt: commonWindow ? now : now.addingTimeInterval(Double(-120 + index * 60) * 86_400),
                validFrom: commonWindow
                    ? now.addingTimeInterval(-14 * 86_400)
                    : now.addingTimeInterval(Double(-134 + index * 60) * 86_400),
                validTo: commonWindow ? now : now.addingTimeInterval(Double(-120 + index * 60) * 86_400),
                aggregateDefinition: commonWindow ? "window=14d-shared" : "window=14d-disjoint",
                sampleCount: 14,
                summary: summary
            )
        }
        let stableID = try HoloMemoryIdentity.makeStableID(
            scope: .crossDomain,
            primaryDomain: nil,
            sourceDomains: domains,
            claimKind: claimKind,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: stableID,
            scope: .crossDomain,
            primaryDomain: nil,
            sourceDomains: domains,
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: claimKind,
            persistenceClass: .phase,
            displaySummary: summary,
            aiUseSummary: summary,
            prohibitedInferences: prohibitedInferences,
            evidenceRefs: evidence,
            upstreamMemoryIDs: ["\(id)-health-memory", "\(id)-finance-memory"],
            counterEvidenceRefs: [],
            validFrom: now.addingTimeInterval(-14 * 86_400),
            validTo: now,
            lastSupportedAt: now,
            confidenceScore: 0.7,
            freshnessScore: 0.9,
            scoringVersion: 1,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .candidate,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: now.addingTimeInterval(-600),
            updatedAt: now
        )
    }

    private static func makeRepeatedEvidenceRecord(
        id: String,
        domain: HoloMemoryDomain,
        summary: String,
        claimKind: HoloMemoryClaimKind,
        windows: [(Double, Double)],
        now: Date = anchorNow
    ) throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(type: anchorType(for: domain), value: "fixture-\(id)-pattern")
        let evidence = windows.enumerated().map { index, window in
            HoloMemoryEvidenceRef(
                id: "\(id)-evidence-\(index)",
                kind: .aggregateSnapshot,
                sourceDomain: domain,
                lineageKey: "\(id)-lineage-w\(index)",
                revisionDigest: "rev-1",
                observedAt: day(window.1, from: now),
                validFrom: day(window.0, from: now),
                validTo: day(window.1, from: now),
                aggregateDefinition: "window=\(index)",
                sampleCount: 20,
                summary: summary
            )
        }
        let stableID = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            claimKind: claimKind,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: stableID,
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: claimKind,
            persistenceClass: .phase,
            displaySummary: summary,
            aiUseSummary: summary,
            prohibitedInferences: [],
            evidenceRefs: evidence,
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            validFrom: day(windows.map(\.0).min() ?? 0, from: now),
            validTo: day(windows.map(\.1).max() ?? 0, from: now),
            lastSupportedAt: now,
            confidenceScore: 0.8,
            freshnessScore: 1,
            scoringVersion: 1,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .candidate,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: day(windows.map(\.0).min() ?? -30, from: now),
            updatedAt: now
        )
    }
}
