//
//  AdversarialRegressionTests.swift
//  Holo
//
//  对抗性回归：边界与恶意输入砸五件套件，找崩溃与逻辑洞（东林 11-13 要求整体回归找 bug）。
//

import Foundation

// 入口在 UnderstandingStandaloneRunner.swift。

struct AdversarialRegressionTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func run() throws {
        emptyInputs()
        weirdTexts()
        timeBoundaries()
        indexAbuse()
        themeAbuse()
        gateAbuse()
        ledgerAbuse()
        performanceSmoke()

        print("AdversarialRegressionTests: \(assertions) assertions passed")
    }

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: 1. 空输入

    static func emptyInputs() {
        expect(FinanceObservationProjector.project([]).isEmpty, "空交易→空观察")
        expect(ThoughtObservationProjector.project([]).isEmpty, "空想法→空观察")
        expect(ThemeIndex.buildThemes(from: []).isEmpty, "空观察→空主题")
        var index = ObservationIndex()
        expect(index.merge([]).isEmpty, "空merge零变化")
        expect(index.replaceDomain(.finance, with: []).isEmpty, "空域替换=清空该域且delta空")
        var ledger = ShadowLedger()
        expect(ledger.evictStale(now: t0).isEmpty, "空台账清扫零处理")
        let router = EvidenceRouter(index: index)
        if case .insufficientEvidence? = router.execute(EvidenceRequest(op: .retrieveRelated, domain: .finance, concepts: ["猫"])).failure {
            expect(true, "空索引查证→显式 insufficientEvidence")
        } else {
            fatalError("空索引 retrieveRelated 必须显式失败")
        }
    }

    // MARK: 2. 怪文本

    static func weirdTexts() {
        // 空白/纯空格备注
        let blank = FinanceObservationProjector.project([
            FinanceObservationInput(id: "w1", note: "   ", occurredAt: t0, recordedAt: t0, updatedAt: t0, isRefund: false, categoryName: nil)])
        expect(blank[0].concepts.isEmpty && blank[0].quote == nil, "纯空白备注→无概念无引用")
        // emoji/英文/数字混排概念
        let mixed = FinanceObservationProjector.concepts(fromNote: "CatFood 🐱 coffee2 latte 猫咪", categoryName: nil)
        expect(mixed.contains("CatFood") && mixed.contains("🐱") && mixed.contains("猫咪"), "英文/emoji/中文概念共存保留")
        expect(!mixed.contains("coffee2"), "含数字token被过滤")
        // 超长备注（1万字）：不崩、概念上限仍生效
        let huge = String(repeating: "猫粮咖啡 ", count: 2000)
        let hugeObs = FinanceObservationProjector.project([
            FinanceObservationInput(id: "w2", note: huge, occurredAt: t0, recordedAt: t0, updatedAt: t0, isRefund: false, categoryName: nil)])
        expect(hugeObs[0].concepts.count == 1, "超长重复备注概念去重后=1（猫粮/咖啡两token循环→上限内去重）")
        // FNV 稳定哈希：emoji 与中文
        expect(ThoughtObservationInput.stableHash("🐱猫") != ThoughtObservationInput.stableHash("猫🐱"), "不同顺序不同哈希")
        // 归属词法：无意义组合不误判
        expect(FinanceObservationProjector.attribution(fromNote: "帮宝适纸尿裤") == .unknown,
               "品牌名含『帮』不含承接动词→不误判代办（帮宝适反例）")
        expect(FinanceObservationProjector.attribution(fromNote: "帮王阿姨带") == .proxy, "真代办仍命中")
    }

    // MARK: 3. 时间边界

    static func timeBoundaries() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // 年界：12-31 23:59 → 1-1 00:00
        let nye = cal.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 59))!
        let nyd = cal.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        let obs = FinanceObservationProjector.project([
            FinanceObservationInput(id: "t1", note: "跨年", occurredAt: nye, recordedAt: nyd, updatedAt: nyd, isRefund: false, categoryName: nil)])
        expect(obs[0].timePrecision == .day, "跨年跨日非零点→day（非补账，精度按跨日降档）")
        // 闰日
        if let feb29 = cal.date(from: DateComponents(year: 2028, month: 2, day: 29, hour: 8)) {
            let leap = FinanceObservationProjector.project([
                FinanceObservationInput(id: "t2", note: "闰日", occurredAt: feb29, recordedAt: feb29, updatedAt: feb29, isRefund: false, categoryName: nil)])
            expect(leap[0].occurredAt == feb29, "闰日日期正常")
        }
        // 零长度窗口的频次比较：不崩、天数为1
        let router = EvidenceRouter(index: ObservationIndex())
        let zero = router.comparePeriods(concept: "猫粮",
                                         baseline: DateInterval(start: t0, duration: 0),
                                         current: DateInterval(start: t0, duration: 0))
        expect(zero.baselineDays == 1 && zero.currentDays == 1 && zero.direction == "flat", "零长度窗口→天数钳1不除零")
        // 相邻秒窗口
        let tiny = router.comparePeriods(concept: "猫粮",
                                         baseline: DateInterval(start: t0, duration: 1),
                                         current: DateInterval(start: t0.addingTimeInterval(1), duration: 1))
        expect(tiny.direction == "flat", "相邻秒窗口→flat")
    }

    // MARK: 4. 索引滥用

    static func indexAbuse() {
        var index = ObservationIndex()
        // 同 ref 反复修订 100 次：始终单条
        for round in 0..<100 {
            _ = index.merge(FinanceObservationProjector.project([
                FinanceObservationInput(id: "dup", note: "猫粮v\(round)", occurredAt: t0, recordedAt: t0, updatedAt: t0.addingTimeInterval(Double(round)), isRefund: false, categoryName: nil)]))
        }
        expect(index.observations.count == 1, "同源100次修订→单条（不膨胀）")
        // 超大概念数组（100 个概念）：主题不崩
        let fatObs = LifeObservation(domain: .finance, sourceRef: "fat", sourceRevision: "r1", sourceKind: "fixture",
                                     occurredAt: t0, recordedAt: t0, timePrecision: .minute,
                                     concepts: (0..<100).map { "概念\($0)" }, action: nil,
                                     attribution: .unknown, businessState: .plain, coverage: nil, quote: nil)
        let themes = ThemeIndex.buildThemes(from: [fatObs,
            fatObs.with(sourceRef: "fat2"), fatObs.with(sourceRef: "fat3")])
        expect(themes.allSatisfy { $0.memberIDs.count == 3 }, "百概念观察成主题且成员完整")
    }

    // MARK: 5. 主题滥用

    static func themeAbuse() {
        // 单字概念（「茶」）不参与锚拆分（≥2字才拆）也不扫原话
        let singleChar = LifeObservation(domain: .finance, sourceRef: "s1", sourceRevision: "r1", sourceKind: "fixture",
                                         occurredAt: t0, recordedAt: t0, timePrecision: .minute,
                                         concepts: ["茶"], action: nil, attribution: .unknown,
                                         businessState: .plain, coverage: nil, quote: nil)
        let themes = ThemeIndex.buildThemes(from: [singleChar, singleChar.with(sourceRef: "s2")])
        expect(themes.first?.key == "茶", "单字概念自成主题key（无锚可拆）")
        // 概念含正则元字符（不影响——词法是contains不是正则）
        let regexish = ThemeIndex.buildThemes(from: [
            LifeObservation(domain: .finance, sourceRef: "rx1", sourceRevision: "r1", sourceKind: "f",
                            occurredAt: t0, recordedAt: t0, timePrecision: .minute,
                            concepts: ["a*b+c"], action: nil, attribution: .unknown,
                            businessState: .plain, coverage: nil, quote: nil),
            LifeObservation(domain: .finance, sourceRef: "rx2", sourceRevision: "r1", sourceKind: "f",
                            occurredAt: t0, recordedAt: t0, timePrecision: .minute,
                            concepts: ["a*b+c"], action: nil, attribution: .unknown,
                            businessState: .plain, coverage: nil, quote: nil),
        ])
        expect(regexish.first?.concepts == ["a*b+c"], "正则元字符概念按字面处理")
    }

    // MARK: 6. 闸滥用

    static func gateAbuse() {
        let observations = [
            LifeObservation(domain: .finance, sourceRef: "g1", sourceRevision: "r1", sourceKind: "f",
                            occurredAt: t0, recordedAt: t0, timePrecision: .minute, concepts: ["猫粮"],
                            action: nil, attribution: .self_, businessState: .plain, coverage: nil, quote: nil),
        ]
        // 非法 claimType
        let bogus = ProposalCandidate(claimType: "totally-bogus", statement: "任意陈述",
                                      supportingRefs: ["g1"], alternativeExplanations: [],
                                      whatWouldChangeTheAnswer: nil, evidenceGrade: nil, action: "adopt")
        let result = ProposalGate.evaluate(candidate: bogus, observations: observations)
        expect(result.accepted && result.action == "adopt" || !result.accepted,
               "非法claimType不崩溃（按无类别处理或拒绝）")
        // 空 statement
        let emptyStatement = ProposalCandidate(claimType: "role", statement: "",
                                               supportingRefs: ["g1"], alternativeExplanations: [],
                                               whatWouldChangeTheAnswer: nil, evidenceGrade: nil, action: "adopt")
        _ = ProposalGate.evaluate(candidate: emptyStatement, observations: observations)
        expect(true, "空命题不崩溃")
        // refs 含空串
        let weirdRefs = ProposalCandidate(claimType: "role", statement: "可能在照料猫",
                                          supportingRefs: ["", "g1", "   "], alternativeExplanations: [],
                                          whatWouldChangeTheAnswer: nil, evidenceGrade: nil, action: "adopt")
        let weirdResult = ProposalGate.evaluate(candidate: weirdRefs, observations: observations)
        expect(!weirdResult.accepted, "含空串/空白引用→按编造引用拒绝（不可回源）")
    }

    // MARK: 7. 台账滥用

    static func ledgerAbuse() {
        var ledger = ShadowLedger()
        // 推进不存在的 id
        expect(ledger.advance(id: "ghost", to: .packaged, now: t0) == nil, "推进不存在id→nil不崩")
        // settle 不存在的 id
        expect(ledger.settle(id: "ghost", gateResult: (true, "adopt", []), now: t0) == nil, "settle不存在id→nil")
        // 无效登记后 advance
        _ = ledger.register(id: "x", themeKey: "猫", now: t0)
        expect(ledger.advance(id: "x", to: .adoptable, now: t0) == nil, "newEvidence直跳adoptable被拒")
        // evictStale 多次调用幂等（第二次无变化）
        _ = ledger.advance(id: "x", to: .packaged, now: t0)
        let first = ledger.evictStale(now: t0.addingTimeInterval(100 * 3600))
        let second = ledger.evictStale(now: t0.addingTimeInterval(100 * 3600))
        expect(!first.isEmpty && second.isEmpty, "清扫幂等：已回炉的未再超时（时间戳已重置）")
    }

    // MARK: 8. 性能冒烟

    static func performanceSmoke() {
        // 5000 条观察投影+索引+主题重建：应在一秒量级（词法路径无重模型）
        let start = Date()
        var inputs: [FinanceObservationInput] = []
        for i in 0..<5000 {
            inputs.append(FinanceObservationInput(
                id: "perf-\(i)",
                note: i % 7 == 0 ? "猫粮" : (i % 7 == 1 ? "咖啡" : "日用\(i % 30)"),
                occurredAt: t0.addingTimeInterval(Double(i) * 600),
                recordedAt: t0.addingTimeInterval(Double(i) * 600),
                updatedAt: t0.addingTimeInterval(Double(i) * 600),
                isRefund: false, categoryName: nil))
        }
        var index = ObservationIndex()
        let observations = FinanceObservationProjector.project(inputs)
        _ = index.merge(observations)
        let themes = ThemeIndex.buildThemes(from: observations)
        let elapsed = Date().timeIntervalSince(start)
        expect(elapsed < 5.0, "5000条投影+索引+主题 <5s（实际 \(elapsed)s，主题数 \(themes.count)）")
        expect(!themes.isEmpty, "5000条输入产出主题非空")
    }
}

extension LifeObservation {
    /// 对抗测试助手：换 sourceRef 复制（同概念多观察构造）。
    func with(sourceRef: String) -> LifeObservation {
        var copy = self
        copy.sourceRef = sourceRef
        return copy
    }
}
