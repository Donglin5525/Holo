//
//  ShadowRuntimeStandaloneTests.swift
//  Holo
//
//  M2.5 影子状态机单测：合法迁移/终态不可逆/滞留超时降级/核验闸集成全流程。
//

import Foundation

// 入口在 UnderstandingStandaloneRunner.swift。

struct ShadowRuntimeStandaloneTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func run() throws {
        testLegalTransitions()
        testTerminalIrreversible()
        testStaleEviction()
        testRequeueCap()
        testFullPipelineWithGate()
        try testPersistenceRoundTrip()

        print("ShadowRuntimeStandaloneTests: \(assertions) assertions passed")
    }

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static func t(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }

    // MARK: 1. 合法迁移

    static func testLegalTransitions() {
        var ledger = ShadowLedger()
        expect(ledger.register(id: "c1", themeKey: "猫", now: t0) != nil, "新候选登记")
        expect(ledger.register(id: "c1", themeKey: "猫", now: t0) == nil, "同 id 未终态重复登记被拒（防僵尸覆盖）")

        expect(ledger.advance(id: "c1", to: .packaged, now: t(1)) != nil, "newEvidence→packaged 合法")
        expect(ledger.advance(id: "c1", to: .proposing, now: t(2)) != nil, "packaged→proposing 合法")
        expect(ledger.advance(id: "c1", to: .awaitingLocalEvidence, now: t(3)) != nil, "proposing→awaitingLocalEvidence 合法")
        expect(ledger.advance(id: "c1", to: .verifying, now: t(4)) != nil, "awaiting→verifying 合法")

        // 非法：跳级与回跳
        var ledger2 = ShadowLedger()
        _ = ledger2.register(id: "c2", themeKey: "咖啡", now: t0)
        expect(ledger2.advance(id: "c2", to: .verifying, now: t(1)) == nil, "newEvidence→verifying 跳级被拒")
        expect(ledger2.advance(id: "c2", to: .adoptable, now: t(1)) == nil, "newEvidence→adoptable 跳级被拒（核验前不得采用）")
        // 提案不可得的合法回炉：awaitingLocalEvidence→newEvidence
        _ = ledger2.advance(id: "c2", to: .packaged, now: t(1))
        _ = ledger2.advance(id: "c2", to: .proposing, now: t(2))
        _ = ledger2.advance(id: "c2", to: .awaitingLocalEvidence, now: t(3))
        expect(ledger2.advance(id: "c2", to: .newEvidence, now: t(4)) != nil, "取证不可得→回炉 newEvidence 合法")
        expect(ledger2.candidates["c2"]?.attempts == 1, "回炉计数+1")
    }

    // MARK: 2. 终态不可逆

    static func testTerminalIrreversible() {
        var ledger = ShadowLedger()
        _ = ledger.register(id: "c3", themeKey: "猫", now: t0)
        _ = ledger.advance(id: "c3", to: .packaged, now: t(1))
        _ = ledger.advance(id: "c3", to: .proposing, now: t(2))
        _ = ledger.advance(id: "c3", to: .awaitingLocalEvidence, now: t(3))
        _ = ledger.advance(id: "c3", to: .verifying, now: t(4))
        _ = ledger.advance(id: "c3", to: .rejected, now: t(5))
        expect(ledger.advance(id: "c3", to: .verifying, now: t(6)) == nil, "rejected→verifying 被拒（终态不可逆）")
        expect(ledger.advance(id: "c3", to: .newEvidence, now: t(6)) == nil, "终态不可回炉")
        // 终态后同 id 可重新登记（新证据=新生命周期）
        expect(ledger.register(id: "c3", themeKey: "猫", now: t(7)) != nil, "终态后同 id 允许重新登记（新生命周期）")
    }

    // MARK: 3. 滞留超时降级（P1-5）

    static func testStaleEviction() {
        var ledger = ShadowLedger()
        _ = ledger.register(id: "stale-1", themeKey: "猫", now: t0)
        _ = ledger.advance(id: "stale-1", to: .packaged, now: t(1))
        _ = ledger.register(id: "fresh-1", themeKey: "咖啡", now: t(70))
        _ = ledger.advance(id: "fresh-1", to: .packaged, now: t(71))
        _ = ledger.register(id: "done-1", themeKey: "夜班", now: t0)
        _ = ledger.advance(id: "done-1", to: .packaged, now: t(1))
        _ = ledger.advance(id: "done-1", to: .proposing, now: t(2))
        _ = ledger.advance(id: "done-1", to: .awaitingLocalEvidence, now: t(3))
        _ = ledger.advance(id: "done-1", to: .verifying, now: t(4))
        _ = ledger.advance(id: "done-1", to: .adoptable, now: t(5))

        let touched = ledger.evictStale(now: t(74))   // stale-1 停留 73h 超时；fresh 3h；done 终态
        expect(touched == ["stale-1"], "仅超时中间态被处理")
        expect(ledger.candidates["stale-1"]?.stage == .newEvidence, "超时候选回炉（不删除，等实质变化）")
        expect(ledger.candidates["stale-1"]?.attempts == 1, "回炉计数入账")
        expect(ledger.candidates["fresh-1"]?.stage == .packaged, "未超时不动")
        expect(ledger.candidates["done-1"]?.stage == .adoptable, "终态不受清扫影响")
    }

    // MARK: 4. 回炉上限

    static func testRequeueCap() {
        var ledger = ShadowLedger()
        _ = ledger.register(id: "capped", themeKey: "猫", now: t0)
        // 三轮完整回炉（回炉合法边=awaitingLocalEvidence→newEvidence，每轮走全链）
        for round in 0..<3 {
            let base = Double(round) * 100
            _ = ledger.advance(id: "capped", to: .packaged, now: t(base + 1))
            _ = ledger.advance(id: "capped", to: .proposing, now: t(base + 2))
            _ = ledger.advance(id: "capped", to: .awaitingLocalEvidence, now: t(base + 3))
            _ = ledger.advance(id: "capped", to: .newEvidence, now: t(base + 4))
        }
        expect(ledger.candidates["capped"]?.attempts == 3, "三轮回炉计数=3")
        // 第四轮推进到中间态后滞留超时
        _ = ledger.advance(id: "capped", to: .packaged, now: t(400))
        let touched = ledger.evictStale(now: t(500))
        expect(touched.contains("capped"), "第4次滞留被处理")
        expect(ledger.candidates["capped"]?.stage == .rejected, "回炉3次后再滞留→rejected（证据长期凑不齐，留诊断不空转）")
    }

    // MARK: 5. 全流程 + 核验闸集成

    static func testFullPipelineWithGate() {
        let observations = [
            LifeObservation(domain: .finance, sourceRef: "f1", sourceRevision: "r1", sourceKind: "transaction",
                            occurredAt: t0, recordedAt: t0, timePrecision: .minute, concepts: ["猫粮"],
                            action: "购买", attribution: .unknown, businessState: .plain, coverage: nil, quote: "猫粮"),
            LifeObservation(domain: .task, sourceRef: "t1", sourceRevision: "r1", sourceKind: "todo",
                            occurredAt: t0, recordedAt: t0, timePrecision: .minute, concepts: ["猫砂盆"],
                            action: "照料", attribution: .self_, businessState: .done, coverage: nil, quote: nil),
            LifeObservation(domain: .thought, sourceRef: "th1", sourceRevision: "r1", sourceKind: "userNote",
                            occurredAt: t0, recordedAt: t0, timePrecision: .minute, concepts: [],
                            action: nil, attribution: .self_, businessState: .quote, coverage: nil, quote: "猫在门口等我"),
        ]
        var ledger = ShadowLedger()
        _ = ledger.register(id: "theme:猫:fp1", themeKey: "猫", now: t0)
        _ = ledger.advance(id: "theme:猫:fp1", to: .packaged, now: t(1))
        _ = ledger.advance(id: "theme:猫:fp1", to: .proposing, now: t(2))
        _ = ledger.advance(id: "theme:猫:fp1", to: .awaitingLocalEvidence, now: t(3))
        _ = ledger.advance(id: "theme:猫:fp1", to: .verifying, now: t(4))

        // 好候选（M1.2 A-semantic 风格）→ adoptable
        let good = ProposalCandidate(claimType: "role", statement: "本人是猫的主要照料者（负责日常清洁与健康）。",
                                     supportingRefs: ["f1", "t1", "th1"], alternativeExplanations: ["代养"],
                                     whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let settled = ledger.settle(id: "theme:猫:fp1", gateResult: ProposalGate.evaluate(candidate: good, observations: observations), now: t(5))
        expect(settled?.stage == .adoptable, "好候选全流程→adoptable（影子期仅入评审视野）")

        // 违规候选（M1.6 S01 病名原文）→ rejected 带闸理由
        var ledger2 = ShadowLedger()
        _ = ledger2.register(id: "theme:照护:fp9", themeKey: "照护", now: t0)
        _ = ledger2.advance(id: "theme:照护:fp9", to: .packaged, now: t(1))
        _ = ledger2.advance(id: "theme:照护:fp9", to: .proposing, now: t(2))
        _ = ledger2.advance(id: "theme:照护:fp9", to: .awaitingLocalEvidence, now: t(3))
        _ = ledger2.advance(id: "theme:照护:fp9", to: .verifying, now: t(4))
        let bad = ProposalCandidate(claimType: "role", statement: "本人是父亲慢性病患者（高血压/糖尿病）的主要照护协调人。",
                                    supportingRefs: ["f1"], alternativeExplanations: ["代买"],
                                    whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let rejected = ledger2.settle(id: "theme:照护:fp9", gateResult: ProposalGate.evaluate(candidate: bad, observations: observations), now: t(5))
        expect(rejected?.stage == .rejected, "病名违规候选→rejected")
        expect(rejected?.lastReason?.contains("疾病身份") == true, "拒绝理由带闸类别（评审可追溯）")

        // 弱证据候选 → observing（降级路径）
        var ledger3 = ShadowLedger()
        _ = ledger3.register(id: "theme:备考:fp2", themeKey: "备考", now: t0)
        _ = ledger3.advance(id: "theme:备考:fp2", to: .packaged, now: t(1))
        _ = ledger3.advance(id: "theme:备考:fp2", to: .proposing, now: t(2))
        _ = ledger3.advance(id: "theme:备考:fp2", to: .awaitingLocalEvidence, now: t(3))
        _ = ledger3.advance(id: "theme:备考:fp2", to: .verifying, now: t(4))
        let weak = ProposalCandidate(claimType: "role", statement: "可能在照料猫。",
                                     supportingRefs: ["f1"], alternativeExplanations: ["代购"],
                                     whatWouldChangeTheAnswer: nil, evidenceGrade: "线索", action: "adopt")
        let observed = ledger3.settle(id: "theme:备考:fp2", gateResult: ProposalGate.evaluate(candidate: weak, observations: observations), now: t(5))
        expect(observed?.stage == .observing, "弱证据 adopt 建议→降级 observing（证据闸降级生效）")
    }

    // MARK: 6. 持久化往返

    static func testPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-ledger-test-\(UUID().uuidString)")
        var ledger = ShadowLedger()
        _ = ledger.register(id: "p1", themeKey: "猫", now: t0)
        _ = ledger.advance(id: "p1", to: .packaged, now: t(1))
        try ledger.save(to: dir)
        let loaded = ShadowLedger.load(directory: dir)
        expect(loaded == ledger, "台账 save/load 往返相等")
        try? FileManager.default.removeItem(at: dir)
    }
}
