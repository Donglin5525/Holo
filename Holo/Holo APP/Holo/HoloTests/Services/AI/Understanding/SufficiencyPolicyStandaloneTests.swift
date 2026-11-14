//
//  SufficiencyPolicyStandaloneTests.swift
//  Holo
//
//  M2.9 水位政策 + M2.10 habit 程序直出单测（2026-11-15 拍板三件事的回归锁）。
//
//  锁定的产品口径：
//  ① 打卡 2 天（3次3天）不得产出「正在戒烟」同级理解——行为轨需持续≥14天且≥10次；
//  ② 用户自述（「开始上夜班」）一次即足——自证豁免广度深度（stated 轨）；
//  ③ 关联类不开自述轨（主观归因不升级因果命题，§5.2）；
//  ④ 三标记随终态落台账（M3 注入按 usage 放行、按 validity 过期）；
//  ⑤ habit 纯主题走程序直出，零模型调用，仍过全闸。
//

import Foundation

// 入口在 UnderstandingStandaloneRunner.swift。

struct SufficiencyPolicyStandaloneTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func run() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        testStatedTrack()
        testPhaseStateWatermark()
        testRoleWatermark()
        testRecurringBehaviorWatermark()
        testPreferenceWatermark()
        testDerivedAndMidnightExcluded()
        testEpistemicTags()
        testSettleWritesTags()
        try testOldLedgerDecode()
        testHabitPhaseProposer()
        try await testRunnerHabitBypassesModel()

        print("SufficiencyPolicyStandaloneTests: \(assertions) assertions passed")
    }

    static let calendar = { () -> Calendar in
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()
    static func day(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    // MARK: 构造 helpers

    static func checkin(_ ref: String, habit: String, at: Date, note: String? = nil) -> LifeObservation {
        LifeObservation(domain: .habit, sourceRef: ref, sourceRevision: "r1", sourceKind: "checkin",
                        occurredAt: at, recordedAt: at, timePrecision: .minute, concepts: [habit],
                        action: "打卡", attribution: .self_, businessState: .done, coverage: nil, quote: note)
    }

    /// 对齐真实投影器（ObservationProjectors）：交易备注 → plain + quote 文本 +
    /// 词法归属（可 proxy）；quote 的 businessState 只在想法域出现。
    static func purchase(_ ref: String, concept: String, at: Date, attribution: ObservationAttribution = .self_, quote: String? = nil) -> LifeObservation {
        LifeObservation(domain: .finance, sourceRef: ref, sourceRevision: "r1", sourceKind: "transaction",
                        occurredAt: at, recordedAt: at, timePrecision: .minute, concepts: [concept],
                        action: "购买", attribution: attribution, businessState: .plain,
                        coverage: nil, quote: quote)
    }

    static func selfNarration(_ ref: String, _ text: String, at: Date) -> LifeObservation {
        LifeObservation(domain: .thought, sourceRef: ref, sourceRevision: "r1", sourceKind: "userNote",
                        occurredAt: at, recordedAt: at, timePrecision: .minute, concepts: [],
                        action: nil, attribution: .self_, businessState: .quote, coverage: nil, quote: text)
    }

    // MARK: 1. stated 轨（用户自述一次即足）

    static func testStatedTrack() {
        // 「开始上夜班」单条自述 → 阶段命题达标（§3 明确案例）
        let nightShift = selfNarration("th1", "从这周开始上夜班了。", at: day(2026, 11, 10))
        let phase = ProposalCandidate(claimType: "phaseState", statement: "最近处于夜班阶段。",
                                      supportingRefs: ["th1"], alternativeExplanations: ["临时替班"],
                                      whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r1 = ProposalGate.evaluate(candidate: phase, observations: [nightShift])
        expect(r1.accepted && r1.action == "adopt", "stated轨：单条自述→阶段命题 adopt")

        // 关联类不开自述轨：「我觉得咖啡影响睡眠」只是 quote 证据，不升级因果命题（§5.2）
        let coffee = selfNarration("th2", "感觉下午的咖啡影响我入睡。", at: day(2026, 11, 10))
        let assoc = ProposalCandidate(claimType: "conditionalAssociation", statement: "下午喝咖啡时更容易晚睡。",
                                      supportingRefs: ["th2"], alternativeExplanations: ["工作压力"],
                                      whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r2 = ProposalGate.evaluate(candidate: assoc, observations: [coffee])
        expect(r2.accepted && r2.action == "observe", "关联类：自述轨不开→单域证据降级 observe")
        expect(r2.reasons.contains { $0.contains("需跨≥2域证据，现1") }, "关联类降级理由点名跨域缺口")
    }

    // MARK: 2. 阶段水位（戒烟——2026-11-15 东林命中的缺口本体）

    static func testPhaseStateWatermark() {
        // 弱：3 天 3 次打卡（旧闸「有引用即过」的缺口场景）
        let weakObs = (0..<3).map { checkin("c\($0)", habit: "戒烟", at: day(2026, 11, 8 + $0)) }
        let weak = ProposalCandidate(claimType: "phaseState", statement: "「戒烟」习惯进行中。",
                                     supportingRefs: weakObs.map(\.sourceRef), alternativeExplanations: [],
                                     whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r1 = ProposalGate.evaluate(candidate: weak, observations: weakObs)
        expect(r1.accepted && r1.action == "observe", "阶段水位：3天3次打卡→降级 observe（不得同级定性）")
        expect(r1.reasons.contains { $0.contains("阶段类需持续≥14天行为证据，现跨度2天") }
               && r1.reasons.contains { $0.contains("阶段类需≥10次行为证据，现3次") },
               "降级理由分别点名跨度与次数缺口")

        // 足：14 天跨度 15 次打卡（day 1..15 每天一次）
        let strongObs = (1...15).map { checkin("q\($0)", habit: "戒烟", at: day(2026, 11, $0)) }
        let strong = ProposalCandidate(claimType: "phaseState", statement: "「戒烟」习惯进行中。",
                                       supportingRefs: strongObs.map(\.sourceRef), alternativeExplanations: [],
                                       whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r2 = ProposalGate.evaluate(candidate: strong, observations: strongObs)
        expect(r2.accepted && r2.action == "adopt", "阶段水位：14天15次打卡→adopt 达标")
    }

    // MARK: 3. 角色水位（猫粮案例 §5.1）

    static func testRoleWatermark() {
        // 2 笔猫粮 span 40 天：旧闸 2 源即过；新水位 occ=2<3 → 降级（短期重复可能是代购）
        let twoObs = [purchase("f1", concept: "猫粮", at: day(2026, 9, 20)),
                      purchase("f2", concept: "猫砂", at: day(2026, 10, 30))]
        let two = ProposalCandidate(claimType: "role", statement: "本人很可能长期照料猫。",
                                    supportingRefs: ["f1", "f2"], alternativeExplanations: ["代购"],
                                    whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r1 = ProposalGate.evaluate(candidate: two, observations: twoObs)
        expect(r1.accepted && r1.action == "observe", "角色水位：2源但仅2次→降级（次数缺口）")
        expect(r1.reasons.contains { $0.contains("角色类需≥3次行为证据，现2次") },
               "角色缺口理由点名次数明细")

        // 3 笔 span ≥30 天 + 本人归属 → 达标
        let threeObs = [purchase("f1", concept: "猫粮", at: day(2026, 9, 1)),
                        purchase("f2", concept: "猫砂", at: day(2026, 9, 20)),
                        purchase("f3", concept: "猫粮", at: day(2026, 10, 5))]
        let three = ProposalCandidate(claimType: "role", statement: "本人很可能长期照料猫。",
                                      supportingRefs: ["f1", "f2", "f3"], alternativeExplanations: ["代购"],
                                      whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r2 = ProposalGate.evaluate(candidate: three, observations: threeObs)
        expect(r2.accepted && r2.action == "adopt", "角色水位：3笔span34天→adopt 达标")

        // 单条自述「我养猫」→ stated 轨豁免广度深度
        let said = selfNarration("th1", "我养了一只猫，日常都是我在照顾。", at: day(2026, 11, 10))
        let stated = ProposalCandidate(claimType: "role", statement: "本人养猫且是主要照料者。",
                                       supportingRefs: ["th1"], alternativeExplanations: [],
                                       whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r3 = ProposalGate.evaluate(candidate: stated, observations: [said])
        expect(r3.accepted && r3.action == "adopt", "角色 stated轨：单条自述→adopt（自证豁免广度）")

        // 代办备注是 quote 但归属 proxy——不构成自证，也不满足本人归属
        let proxyObs = [purchase("f1", concept: "猫粮", at: day(2026, 9, 1), attribution: .proxy, quote: "帮同事带的猫粮"),
                        purchase("f2", concept: "猫砂", at: day(2026, 9, 20), attribution: .proxy, quote: "帮同事带的猫砂"),
                        purchase("f3", concept: "猫粮", at: day(2026, 10, 5), attribution: .proxy, quote: "帮同事带的猫粮")]
        let proxy = ProposalCandidate(claimType: "role", statement: "本人很可能长期照料猫。",
                                      supportingRefs: ["f1", "f2", "f3"], alternativeExplanations: [],
                                      whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r4 = ProposalGate.evaluate(candidate: proxy, observations: proxyObs)
        expect(r4.accepted && r4.action == "observe", "代办 quote 不算自证：缺本人归属→降级")
        expect(r4.reasons.contains { $0.contains("缺本人归属证据") }, "代办降级理由点名归属缺口")
    }

    // MARK: 4. 重复行为水位（M1 羽毛球案例收紧固化）

    static func testRecurringBehaviorWatermark() {
        // 3 次 span 21 天：旧闸过；新水位 span<30 → 降级（§3 重复三次不自动值得展示）
        let shortObs = [purchase("b1", concept: "羽毛球", at: day(2026, 10, 5)),
                        purchase("b2", concept: "羽毛球", at: day(2026, 10, 13)),
                        purchase("b3", concept: "羽毛球", at: day(2026, 10, 26))]
        let short = ProposalCandidate(claimType: "recurringBehavior", statement: "经常打羽毛球。",
                                      supportingRefs: ["b1", "b2", "b3"], alternativeExplanations: [],
                                      whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r1 = ProposalGate.evaluate(candidate: short, observations: shortObs)
        expect(r1.accepted && r1.action == "observe", "重复行为：3次span21天→降级（跨度不足）")

        let longObs = [purchase("b1", concept: "羽毛球", at: day(2026, 9, 25)),
                       purchase("b2", concept: "羽毛球", at: day(2026, 10, 13)),
                       purchase("b3", concept: "羽毛球", at: day(2026, 10, 27))]
        let long = ProposalCandidate(claimType: "recurringBehavior", statement: "经常打羽毛球。",
                                     supportingRefs: ["b1", "b2", "b3"], alternativeExplanations: [],
                                     whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r2 = ProposalGate.evaluate(candidate: long, observations: longObs)
        expect(r2.accepted && r2.action == "adopt", "重复行为：3次span32天→adopt 达标")
    }

    // MARK: 5. 偏好水位（无跨度要求，只看次数）

    static func testPreferenceWatermark() {
        let twoObs = [purchase("p1", concept: "燕麦拿铁", at: day(2026, 10, 20)),
                      purchase("p2", concept: "燕麦拿铁", at: day(2026, 11, 1))]
        let two = ProposalCandidate(claimType: "preference", statement: "偏好燕麦拿铁。",
                                    supportingRefs: ["p1", "p2"], alternativeExplanations: [],
                                    whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r1 = ProposalGate.evaluate(candidate: two, observations: twoObs)
        expect(r1.accepted && r1.action == "observe", "偏好：2次同类选择→降级")

        let threeObs = twoObs + [purchase("p3", concept: "燕麦拿铁", at: day(2026, 11, 12))]
        let three = ProposalCandidate(claimType: "preference", statement: "偏好燕麦拿铁。",
                                      supportingRefs: ["p1", "p2", "p3"], alternativeExplanations: [],
                                      whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r2 = ProposalGate.evaluate(candidate: three, observations: threeObs)
        expect(r2.accepted && r2.action == "adopt", "偏好：3次同类选择→adopt 达标")
    }

    // MARK: 6. derived / midnightDefault 不进水位

    static func testDerivedAndMidnightExcluded() {
        // derived（AI 摘要）不算行为证据：2 derived + 1 真实 → sources=1 → 角色降级
        let mixed = [purchase("f1", concept: "猫粮", at: day(2026, 9, 1)),
                     LifeObservation(domain: .finance, sourceRef: "d1", sourceRevision: "r1", sourceKind: "summary",
                                     occurredAt: day(2026, 9, 10), recordedAt: day(2026, 9, 10), timePrecision: .minute,
                                     concepts: ["猫粮"], action: "购买", attribution: .unknown,
                                     businessState: .derived, coverage: nil, quote: nil),
                     LifeObservation(domain: .finance, sourceRef: "d2", sourceRevision: "r1", sourceKind: "summary",
                                     occurredAt: day(2026, 9, 20), recordedAt: day(2026, 9, 20), timePrecision: .minute,
                                     concepts: ["猫砂"], action: "购买", attribution: .unknown,
                                     businessState: .derived, coverage: nil, quote: nil)]
        let role = ProposalCandidate(claimType: "role", statement: "本人很可能长期照料猫。",
                                     supportingRefs: ["f1", "d1", "d2"], alternativeExplanations: [],
                                     whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r1 = ProposalGate.evaluate(candidate: role, observations: mixed)
        expect(r1.accepted && r1.action == "observe", "derived 不算独立行为证据→降级")
        expect(r1.reasons.contains { $0.contains("需≥2独立来源，现1") }, "derived 缺口理由点名来源数")

        // midnightDefault（补账默认午夜）不进深度计算：15 次里 13 次是午夜默认 → 有效仅 2 次 → 降级
        var backfilled: [LifeObservation] = []
        for i in 1...2 {
            backfilled.append(checkin("real\(i)", habit: "戒烟", at: day(2026, 11, i)))
        }
        for i in 3...15 {
            let obs = checkin("mid\(i)", habit: "戒烟", at: day(2026, 11, i, 0))
            backfilled.append(LifeObservation(domain: obs.domain, sourceRef: obs.sourceRef, sourceRevision: obs.sourceRevision,
                                              sourceKind: obs.sourceKind, occurredAt: obs.occurredAt, recordedAt: obs.recordedAt,
                                              timePrecision: .midnightDefault, concepts: obs.concepts, action: obs.action,
                                              attribution: obs.attribution, businessState: obs.businessState,
                                              coverage: obs.coverage, quote: obs.quote))
        }
        let phase = ProposalCandidate(claimType: "phaseState", statement: "「戒烟」习惯进行中。",
                                      supportingRefs: backfilled.map(\.sourceRef), alternativeExplanations: [],
                                      whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let r2 = ProposalGate.evaluate(candidate: phase, observations: backfilled)
        expect(r2.accepted && r2.action == "observe", "午夜默认时间不进深度→降级（补账时间不可信）")
    }

    // MARK: 7. 三标记推导

    static func testEpistemicTags() {
        let quoteObs = selfNarration("th1", "我养了一只猫。", at: day(2026, 11, 1))
        let plainObs = purchase("f1", concept: "猫粮", at: day(2026, 10, 1))
        expect(EpistemicTags.provenance(cited: [quoteObs, plainObs]) == .stated, "含本人原话→stated")
        expect(EpistemicTags.provenance(cited: [plainObs]) == .recorded, "纯行为记录→recorded")
        expect(EpistemicTags.validity(kind: .role) == .enduring, "角色→持续有效")
        expect(EpistemicTags.validity(kind: .preference) == .enduring, "偏好→持续有效")
        expect(EpistemicTags.validity(kind: .phaseState) == .phase, "阶段→阶段性（断证过期）")
        expect(EpistemicTags.validity(kind: .recurringBehavior) == .phase, "重复行为→阶段性")
        expect(EpistemicTags.validity(kind: .conditionalAssociation) == .conditional, "关联→条件性")
        expect(EpistemicUsage.forStage(.adoptable) == .explicitBackground, "adoptable→可作为明确背景")
        expect(EpistemicUsage.forStage(.observing) == .internalOnly, "observing→仅内部观察")
        expect(EpistemicUsage.forStage(.askWhenRelevant) == .internalOnly, "补问在途→仅内部观察")
        expect(EpistemicUsage.forStage(.rejected) == nil, "拒绝→无使用范围")
    }

    // MARK: 8. settle 落三标记

    static func testSettleWritesTags() {
        let obs = [purchase("f1", concept: "猫粮", at: day(2026, 9, 1)),
                   purchase("f2", concept: "猫砂", at: day(2026, 9, 20)),
                   purchase("f3", concept: "猫粮", at: day(2026, 10, 5))]
        var ledger = ShadowLedger()
        _ = ledger.register(id: "theme:猫:fp1", themeKey: "猫", now: day(2026, 11, 1))
        _ = ledger.advance(id: "theme:猫:fp1", to: .packaged, now: day(2026, 11, 1, 1))
        _ = ledger.advance(id: "theme:猫:fp1", to: .proposing, now: day(2026, 11, 1, 2))
        _ = ledger.advance(id: "theme:猫:fp1", to: .awaitingLocalEvidence, now: day(2026, 11, 1, 3))
        _ = ledger.advance(id: "theme:猫:fp1", to: .verifying, now: day(2026, 11, 1, 4))
        let candidate = ProposalCandidate(claimType: "role", statement: "本人很可能长期照料猫。",
                                          supportingRefs: ["f1", "f2", "f3"], alternativeExplanations: ["代购"],
                                          whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let settled = ledger.settle(id: "theme:猫:fp1",
                                    gateResult: ProposalGate.evaluate(candidate: candidate, observations: obs),
                                    provenance: .recorded, validity: .enduring, now: day(2026, 11, 1, 5))
        expect(settled?.stage == .adoptable, "三标记用例：达标候选→adoptable")
        expect(settled?.provenance == .recorded, "settle 落 provenance")
        expect(settled?.validity == .enduring, "settle 落 validity")
        expect(settled?.usage == .explicitBackground, "settle 按 stage 推导 usage=明确背景")
    }

    // MARK: 9. 旧台账 JSON 兼容（缺三标记字段解码不炸）

    static func testOldLedgerDecode() throws {
        // 旧形状：无 provenance/validity/usage 三 key（Apple deferredToDate 时间戳）
        let json = """
        {"candidates":{"theme:猫:fp1":{"id":"theme:猫:fp1","themeKey":"猫","stage":"observing","enteredStageAt":811692800,"attempts":0}}}
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("old-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("shadow-ledger.json"))
        let ledger = ShadowLedger.load(directory: dir)
        expect(ledger.snapshot().count == 1, "旧台账（无三标记）解码成功")
        expect(ledger.snapshot().first?.provenance == nil, "旧条目三标记为 nil（不搬家、不误标）")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: 10. habit 程序直出（HabitPhaseProposer）

    static func testHabitPhaseProposer() {
        let proposer = HabitPhaseProposer()

        // 14 天 15 次连续打卡 → adopt 候选，模板措辞
        let steady = (1...15).map { checkin("q\($0)", habit: "戒烟", at: day(2026, 11, $0)) }
        let steadyOut = proposer.propose(themeKey: "戒烟", members: steady, now: day(2026, 11, 16))
        expect(steadyOut.count == 1, "直出：稳定打卡产出 1 条候选")
        expect(steadyOut[0].claimType == "phaseState" && steadyOut[0].action == "adopt", "直出：达标→phaseState/adopt")
        expect(steadyOut[0].statement == "「戒烟」习惯进行中", "直出：模板措辞零幻觉")
        expect(steadyOut[0].supportingRefs.count == 15, "直出：全量 refs（水位计算不被截断）")
        // 直出候选过全闸
        let gateSteady = ProposalGate.evaluate(candidate: steadyOut[0], observations: steady)
        expect(gateSteady.accepted && gateSteady.action == "adopt", "直出：达标候选过闸 adopt")

        // 15 次但两段中断（day1-10 / 13-16 / 19）→「期间有反复」（戒烟反复期实证）
        var breakDates: [Date] = []
        for d in 1...10 { breakDates.append(day(2026, 11, d)) }
        for d in 13...16 { breakDates.append(day(2026, 11, d)) }
        breakDates.append(day(2026, 11, 19))
        let broken = breakDates.enumerated().map { checkin("b\($0.offset)", habit: "戒烟", at: $0.element) }
        let brokenOut = proposer.propose(themeKey: "戒烟", members: broken, now: day(2026, 11, 20))
        expect(brokenOut[0].statement.contains("期间有反复"), "直出：两段中断→反复注记")

        // 3 次 3 天 → observe 候选（线索保留）
        let weak = (1...3).map { checkin("w\($0)", habit: "维生素", at: day(2026, 11, $0)) }
        let weakOut = proposer.propose(themeKey: "维生素", members: weak, now: day(2026, 11, 4))
        expect(weakOut.count == 1 && weakOut[0].action == "observe", "直出：3次→observe 线索")
        let gateWeak = ProposalGate.evaluate(candidate: weakOut[0], observations: weak)
        expect(gateWeak.accepted && gateWeak.action == "observe", "直出：弱候选过闸降级 observe（与模型通道同标准）")

        // 2 次 → 空数组（弱信号不成命题）
        let tiny = (1...2).map { checkin("t\($0)", habit: "喝水", at: day(2026, 11, $0)) }
        expect(proposer.propose(themeKey: "喝水", members: tiny, now: day(2026, 11, 3)).isEmpty, "直出：2次→空数组")

        // habitName 含医疗化词（用户自建「焦虑症日记」）→ 直出候选被措辞闸拦（特性）
        let sensitive = (1...15).map { checkin("s\($0)", habit: "焦虑症日记", at: day(2026, 11, $0)) }
        let sensitiveOut = proposer.propose(themeKey: "焦虑症日记", members: sensitive, now: day(2026, 11, 16))
        let gateSensitive = ProposalGate.evaluate(candidate: sensitiveOut[0], observations: sensitive)
        expect(!gateSensitive.accepted, "直出：敏感习惯名被措辞闸拦（系统不复述自我医疗化）")
    }

    // MARK: 11. Runner 分流：habit 纯主题零模型调用

    /// 模型通道间谍：habit 纯主题一次都不该被调（程序直出接管）。
    /// class 引用类型——struct 传入后是拷贝，计数回不到调用方（首版笔误防复发）。
    final class SpyProposeClient: UnderstandingProposeClient, @unchecked Sendable {
        var calls = 0
        func propose(themeKey: String, evidence: [SemanticEvidenceItem]) async throws -> [ProposalCandidate] {
            calls += 1
            return []
        }
    }

    static func testRunnerHabitBypassesModel() async throws {
        // 15 天戒烟打卡（不打勾 note）→ habit 纯主题
        var habitInputs: [HabitObservationInput] = []
        for d in 1...15 {
            habitInputs.append(HabitObservationInput(
                recordID: "rec-\(d)", habitID: "habit-1", habitName: "戒烟",
                isNumeric: false, isCompleted: true, note: nil,
                occurredAt: day(2026, 11, d), updatedAt: day(2026, 11, d)))
        }
        let spy = SpyProposeClient()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-habit-\(UUID().uuidString)")
        let report = await UnderstandingShadowRunner.runOnce(
            now: day(2026, 11, 16, 23),
            maxTopics: 3,
            storage: dir,
            loadInputs: { ([], [], habitInputs) },
            proposeClient: spy)

        expect(spy.calls == 0, "分流：habit 纯主题零模型调用（程序直出接管）")
        expect(report.proposalsReceived == 1, "直出候选计入提案数（评审可见）")
        let ledger = ShadowLedger.load(directory: dir)
        let adoptable = ledger.snapshot(stage: .adoptable)
        expect(adoptable.count == 1, "分流：戒烟直出候选→adoptable")
        expect(adoptable[0].validity == .phase, "分流：台账落 validity=phase（断证过期依据）")
        expect(adoptable[0].usage == .explicitBackground, "分流：台账落 usage=明确背景")
        expect(adoptable[0].provenance == .recorded, "分流：纯打卡→provenance=recorded")
        try? FileManager.default.removeItem(at: dir)

        // 混域主题仍走模型：财务+想法世界（无 habit）→ spy 被调。
        // 财务给 2 笔猫相关（首字锚「猫」聚簇——单观察会被主题层噪声过滤）。
        let financeInputs = [
            FinanceObservationInput(
                id: "cat-1", note: "猫粮", occurredAt: day(2026, 10, 1), recordedAt: day(2026, 10, 1),
                updatedAt: day(2026, 10, 1), isRefund: false, categoryName: nil),
            FinanceObservationInput(
                id: "cat-2", note: "猫砂", occurredAt: day(2026, 10, 20), recordedAt: day(2026, 10, 20),
                updatedAt: day(2026, 10, 20), isRefund: false, categoryName: nil),
        ]
        let thoughtInputs = [ThoughtObservationInput(
            id: "th-1", text: "猫在门口等我。", createdAt: day(2026, 10, 2), updatedAt: day(2026, 10, 2), isAIDerived: false)]
        let spy2 = SpyProposeClient()
        let dir2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-model-\(UUID().uuidString)")
        let report2 = await UnderstandingShadowRunner.runOnce(
            now: day(2026, 11, 16, 23), maxTopics: 3, storage: dir2,
            loadInputs: { (financeInputs, thoughtInputs, []) },
            proposeClient: spy2)
        expect(report2.topicsProcessed >= 1 && spy2.calls >= 1,
               "混域主题（finance+thought）仍走模型通道（processed=\(report2.topicsProcessed) calls=\(spy2.calls)）")
        try? FileManager.default.removeItem(at: dir2)
    }
}
