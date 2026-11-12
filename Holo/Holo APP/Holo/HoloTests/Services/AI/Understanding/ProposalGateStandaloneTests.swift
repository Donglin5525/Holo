//
//  ProposalGateStandaloneTests.swift
//  Holo
//
//  M2.4 核验闸单测：词表规则 + M1.6 轮1 实测候选回放（2 硬违规必拦、拆台/正常必放）。
//  跑法：bash scripts/run-understanding-standalone.sh（同批编译）。
//

import Foundation

// 入口在 UnderstandingStandaloneRunner.swift（两套件共用一个 @main）。

struct ProposalGateStandaloneTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func main2() async throws {
        setvbuf(stdout, nil, _IONBF, 0)

        testWordingRules()
        testStrengthGate()
        testEvidenceGate()
        replayM16HardViolations()
        replayM16GoodCandidates()

        print("ProposalGateStandaloneTests: \(assertions) assertions passed")
    }

    // MARK: 最小观察夹具

    static func obs(_ ref: String, domain: ObservationDomain, attribution: ObservationAttribution,
                    state: ObservationBusinessState = .plain) -> LifeObservation {
        LifeObservation(domain: domain, sourceRef: ref, sourceRevision: "r1", sourceKind: "fixture",
                        occurredAt: Date(timeIntervalSince1970: 1_790_000_000),
                        recordedAt: Date(timeIntervalSince1970: 1_790_000_000),
                        timePrecision: .minute, concepts: ["夹具"], action: nil,
                        attribution: attribution, businessState: state, coverage: nil, quote: nil)
    }

    static func candidate(_ type: String, _ statement: String, refs: [String], action: String = "adopt") -> ProposalCandidate {
        ProposalCandidate(claimType: type, statement: statement, supportingRefs: refs,
                          alternativeExplanations: ["竞争解释"], whatWouldChangeTheAnswer: nil,
                          evidenceGrade: "支持", action: action)
    }

    // MARK: 1. 措辞闸规则

    static func testWordingRules() {
        expect(!ProposalGate.wordingGate(candidate("phaseState", "咖啡导致晚睡", refs: ["a"])).passed,
               "因果词拦截")
        expect(!ProposalGate.wordingGate(candidate("role", "该用户自律差且有拖延症", refs: ["a"])).passed,
               "人格标签拦截")
        expect(!ProposalGate.wordingGate(candidate("phaseState", "其限额可能因成瘾机制失效", refs: ["a"])).passed,
               "成瘾机制拦截（M1.6 S09 实例）")
        expect(!ProposalGate.wordingGate(candidate("role", "本人是高血压患者的照护者", refs: ["a"])).passed,
               "疾病身份措辞拦截（患者一词，M1.6 S01 变体）")
        expect(!ProposalGate.wordingGate(candidate("role", "父亲是慢性病患者（高血压）", refs: ["a"])).passed,
               "病名分离变体也拦（M1.6 S01 原文形态）")
        expect(!ProposalGate.wordingGate(candidate("phaseState", "婴儿约0-6个月处于早期", refs: ["a"])).passed,
               "月龄精确化拦截（M1.6 S02 实例）")
        // 不误伤：时间窗表述
        expect(ProposalGate.wordingGate(candidate("phaseState", "近3个月主动减少社交", refs: ["a"])).passed,
               "时间窗『近3个月』不误伤（词表窄化验证）")
        expect(ProposalGate.wordingGate(candidate("phaseState", "近一个月活动量下降", refs: ["a"])).passed,
               "『近一个月』不误伤")
        // 条件句豁免：医疗词在查证语境不拦
        expect(ProposalGate.wordingGate(candidate("phaseState", "若持续两周情绪低落则建议就医评估", refs: ["a"])).passed,
               "条件句就医话术豁免")
        expect(!ProposalGate.wordingGate(candidate("phaseState", "该用户患有抑郁症", refs: ["a"])).passed,
               "非条件语境医疗断言仍拦")
    }

    // MARK: 2. 强度闸

    static func testStrengthGate() {
        expect(!ProposalGate.strengthGate(candidate("role", "本人一直是猫的主要照料者", refs: ["a"])).passed,
               "role 类确定档措辞拦截")
        expect(ProposalGate.strengthGate(candidate("phaseState", "最近一个月处于调整期", refs: ["a"])).passed,
               "phaseState 不受确定档封顶（阶段本身即暂时）")
        expect(ProposalGate.strengthGate(candidate("role", "本人很可能长期照料猫", refs: ["a"])).passed,
               "『很可能』是 role 类顶格合法档")
    }

    // MARK: 3. 证据闸

    static func testEvidenceGate() {
        let rich = [
            obs("f1", domain: .finance, attribution: .unknown),
            obs("t1", domain: .task, attribution: .self_, state: .done),
            obs("th1", domain: .thought, attribution: .self_, state: .quote),
        ]
        expect(ProposalGate.evidenceGate(candidate: candidate("role", "很可能照料猫", refs: ["f1", "t1", "th1"]),
                                         observations: rich).passed
               && ProposalGate.evidenceGate(candidate: candidate("role", "很可能照料猫", refs: ["f1", "t1", "th1"]),
                                            observations: rich).downgradeTo == nil,
               "role 类：≥2独立来源+本人归属 → 通过不降级")
        let weak = ProposalGate.evidenceGate(candidate: candidate("role", "可能在照料猫", refs: ["f1"]),
                                             observations: rich)
        expect(weak.passed && weak.downgradeTo == "observe",
               "role 类单来源 → 降级 observe（不拒，保留观察）")
        let proxyOnly = ProposalGate.evidenceGate(candidate: candidate("role", "可能在照料猫", refs: ["p1"]),
                                                  observations: [obs("p1", domain: .finance, attribution: .proxy)])
        expect(proxyOnly.downgradeTo == "observe",
               "纯代办归属不构成 role 证据 → 降级（M1.6 代购拆台的程序侧防线）")
        let singleDomain = ProposalGate.evidenceGate(
            candidate: candidate("conditionalAssociation", "晚购咖啡日更易晚睡", refs: ["c1", "c2"]),
            observations: [obs("c1", domain: .finance, attribution: .self_),
                           obs("c2", domain: .finance, attribution: .self_)])
        expect(singleDomain.downgradeTo == "observe", "关联类单域证据 → 降级")
        let fabricated = ProposalGate.evidenceGate(
            candidate: candidate("role", "可能养猫", refs: ["ghost"]),
            observations: rich)
        expect(!fabricated.passed, "引用编造观察 → 直接拒（不可回源）")
    }

    // MARK: 4. M1.6 硬违规回放（真实模型输出原文）

    static func replayM16HardViolations() {
        // S01-normal 候选1 原文（2026-11-13 轮1 实测输出）
        let s01 = ProposalCandidate(
            claimType: "role",
            statement: "本人是父亲慢性病患者（高血压/糖尿病）的主要照护协调人，负责药物补给与复查管理。",
            supportingRefs: ["o1", "o2", "o4"], alternativeExplanations: ["仅代买药", "其他亲属"],
            whatWouldChangeTheAnswer: "用药提醒与复查协调", evidenceGrade: "支持", action: "adopt")
        let verdict1 = ProposalGate.evaluate(candidate: s01, observations: [])
        expect(!verdict1.accepted && verdict1.reasons.contains { $0.contains("疾病身份断言") },
               "回放S01：病名反推必须被措辞闸拦截（实测硬违规#1）")

        // S09-normal 候选2 原文
        let s09 = ProposalCandidate(
            claimType: "phaseState",
            statement: "用户正处于“行为失控后的补救尝试期”，其设定的硬性约束（超200卸载）可能因成瘾机制或沉没成本效应而难以严格执行。",
            supportingRefs: ["o1", "o2"], alternativeExplanations: ["已成功执行"],
            whatWouldChangeTheAnswer: "限额提醒", evidenceGrade: "线索", action: "observe")
        let verdict2 = ProposalGate.evaluate(candidate: s09, observations: [])
        expect(!verdict2.accepted && verdict2.reasons.contains { $0.contains("人格/道德标签") },
               "回放S09：成瘾机制必须被拦（实测硬违规#2）")
    }

    // MARK: 5. M1.6 好候选回放（拆台与正常必须放行）

    static func replayM16GoodCandidates() {
        let observations = [
            obs("f1", domain: .finance, attribution: .proxy),   // 猫粮（帮邻居带）
            obs("t1", domain: .task, attribution: .self_, state: .done),
            obs("th1", domain: .thought, attribution: .self_, state: .quote),
        ]
        // S01-counter 候选1 原文（拆台正确识别）
        let s01c = ProposalCandidate(
            claimType: "role",
            statement: "本人近期承担了为同事老周代购降压药及陪诊跑腿的代办角色。",
            supportingRefs: ["f1", "t1"], alternativeExplanations: ["自家共用账户"],
            whatWouldChangeTheAnswer: "代办类提醒", evidenceGrade: "支持", action: "adopt")
        let v1 = ProposalGate.evaluate(candidate: s01c, observations: observations)
        expect(v1.accepted && v1.action == "adopt", "回放S01拆台：代办角色正确识别且放行")

        // M1.2 A-semantic 风格（正常好候选）
        let good = ProposalCandidate(
            claimType: "role",
            statement: "本人是猫的主要照料者（负责日常清洁、健康管理和饮食决策）。",
            supportingRefs: ["f1", "t1", "th1"], alternativeExplanations: ["代养", "室友的猫"],
            whatWouldChangeTheAnswer: "出行清单纳入喂养安排", evidenceGrade: "支持", action: "adopt")
        let v2 = ProposalGate.evaluate(candidate: good, observations: observations)
        expect(v2.accepted && v2.action == "adopt" && v2.reasons.isEmpty,
               "回放A-normal：照料者候选完整通过（无降级无理由）")

        // S04-weak 原文风格（弱证据，模型给了 ask——证据闸不降 ask，保留补问通道）
        let weak = ProposalCandidate(
            claimType: "phaseState",
            statement: "该用户处于备考的启动或犹豫阶段，尚未进入实质性的执行状态。",
            supportingRefs: ["th1"], alternativeExplanations: ["替他人购书"],
            whatWouldChangeTheAnswer: "学习计划建议", evidenceGrade: "线索", action: "ask")
        let v3 = ProposalGate.evaluate(candidate: weak, observations: observations)
        expect(v3.accepted && v3.action == "ask", "回放S04-weak：ask 动作保留（补问通道不被证据闸吞掉）")
    }
}
