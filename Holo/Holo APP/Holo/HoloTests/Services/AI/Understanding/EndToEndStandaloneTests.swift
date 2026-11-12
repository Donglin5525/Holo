//
//  EndToEndStandaloneTests.swift
//  Holo
//
//  M2.7 端到端：合成输入 → 投影 → 索引 → 主题 → 提案（真实输出 fixture）
//  → 取证（真路由）→ 核验（真闸）→ 影子台账终态 → 评审导出（M2.8）。
//  不调模型（提案用 M1.2 实测输出等价 fixture）——本文件是可重复回归件。
//

import Foundation

// 入口在 UnderstandingStandaloneRunner.swift。

struct EndToEndStandaloneTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func run() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        try goodCandidatePipeline()
        try violatingCandidatePipeline()
        try exportReviewPackage()

        print("EndToEndStandaloneTests: \(assertions) assertions passed")
    }

    static let calendar = { () -> Calendar in
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()
    static func day(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    /// 全链起点：caseA 合成输入（与 M2.2 夹具同源，走真实投影器）。
    static func buildWorld() -> (index: ObservationIndex, themes: [ObservationTheme]) {
        var index = ObservationIndex()
        _ = index.merge(FinanceObservationProjector.project([
            FinanceObservationInput(id: "cat-1", note: "猫粮", occurredAt: day(2026, 8, 14, 19), recordedAt: day(2026, 8, 14, 19), updatedAt: day(2026, 8, 14, 19), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-2", note: "猫粮 5kg", occurredAt: day(2026, 9, 2, 20), recordedAt: day(2026, 9, 2, 20), updatedAt: day(2026, 9, 2, 20), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-3", note: "猫砂豆腐砂", occurredAt: day(2026, 9, 25, 12), recordedAt: day(2026, 9, 25, 12), updatedAt: day(2026, 9, 25, 12), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-4", note: "猫粮", occurredAt: day(2026, 10, 11, 19), recordedAt: day(2026, 10, 11, 19), updatedAt: day(2026, 10, 11, 19), isRefund: false, categoryName: nil),
        ]))
        _ = index.merge(ThoughtObservationProjector.project([
            ThoughtObservationInput(id: "th-1", text: "今晚加班回家，猫在门口等我。", createdAt: day(2026, 9, 26, 23), updatedAt: day(2026, 9, 26, 23), isAIDerived: false),
            ThoughtObservationInput(id: "th-2", text: "猫最近掉毛厉害，查一下是不是该换粮了。", createdAt: day(2026, 10, 12, 8), updatedAt: day(2026, 10, 12, 8), isAIDerived: false),
        ]))
        _ = index.merge([
            LifeObservation(domain: .task, sourceRef: "task-1", sourceRevision: "r1", sourceKind: "todo",
                            occurredAt: day(2026, 9, 6, 9), recordedAt: day(2026, 9, 6, 9),
                            timePrecision: .minute, concepts: ["猫砂盆"], action: "照料",
                            attribution: .self_, businessState: .done, coverage: nil, quote: "打扫猫砂盆"),
        ])
        let themes = ThemeIndex.buildThemes(from: index.observations.values.map { $0 })
        return (index, themes)
    }

    // MARK: 好候选全链（M1.2 A-semantic 真实输出等价 fixture）

    static func goodCandidatePipeline() throws {
        let world = buildWorld()
        let catTheme = world.themes.first { $0.key == "猫" }
        expect(catTheme != nil, "端到端①主题：猫主题聚出")
        expect(catTheme!.isCrossDomain, "端到端②跨域：finance+task+thought")

        var ledger = ShadowLedger()
        let candidateID = "theme:猫:\(catTheme!.fingerprint.prefix(8))"
        expect(ledger.register(id: candidateID, themeKey: "猫", now: day(2026, 11, 1)) != nil, "端到端③登记")

        // 提案 fixture：M1.2 m12-A-semantic 的真实命题（statement 逐字）
        let proposal = ProposalCandidate(
            claimType: "role",
            statement: "本人是猫的主要照料者（负责日常清洁、健康管理和饮食决策）。",
            supportingRefs: ["cat-1", "task-1", "th-1"],
            alternativeExplanations: ["仅是代买或临时帮忙", "室友的猫"],
            whatWouldChangeTheAnswer: "出行清单纳入喂养安排",
            evidenceGrade: "支持", action: "adopt")

        // 取证：归属查证（真路由）
        let router = EvidenceRouter(index: world.index)
        let ownership = router.execute(EvidenceRequest(op: .checkOwnership, domain: .finance,
                                                       sourceRefs: ["cat-1", "cat-4", "th-1"]))
        expect(ownership.payload?.ownership?.selfEvidenced.contains("th-1") == true, "端到端④取证：原话计本人证据")

        // 核验（真闸）→ 影子台账
        _ = ledger.advance(id: candidateID, to: .packaged, now: day(2026, 11, 1, 1))
        _ = ledger.advance(id: candidateID, to: .proposing, now: day(2026, 11, 1, 2))
        _ = ledger.advance(id: candidateID, to: .awaitingLocalEvidence, now: day(2026, 11, 1, 3))
        _ = ledger.advance(id: candidateID, to: .verifying, now: day(2026, 11, 1, 4))
        let gateResult = ProposalGate.evaluate(candidate: proposal,
                                               observations: world.index.observations.values.map { $0 })
        let settled = ledger.settle(id: candidateID, gateResult: gateResult, now: day(2026, 11, 1, 5))
        expect(settled?.stage == .adoptable, "端到端⑤核验+落账：好候选→adoptable（影子期仅评审视野）")
    }

    // MARK: 违规候选全链（M1.6 S01 病名原文）

    static func violatingCandidatePipeline() throws {
        let world = buildWorld()
        var ledger = ShadowLedger()
        let id = "theme:照护:bad00001"
        _ = ledger.register(id: id, themeKey: "照护", now: day(2026, 11, 1))
        _ = ledger.advance(id: id, to: .packaged, now: day(2026, 11, 1, 1))
        _ = ledger.advance(id: id, to: .proposing, now: day(2026, 11, 1, 2))
        _ = ledger.advance(id: id, to: .awaitingLocalEvidence, now: day(2026, 11, 1, 3))
        _ = ledger.advance(id: id, to: .verifying, now: day(2026, 11, 1, 4))
        let violating = ProposalCandidate(
            claimType: "role",
            statement: "本人是父亲慢性病患者（高血压/糖尿病）的主要照护协调人，负责药物补给与复查管理。",
            supportingRefs: ["cat-1"], alternativeExplanations: ["代买"],
            whatWouldChangeTheAnswer: nil, evidenceGrade: "支持", action: "adopt")
        let settled = ledger.settle(id: id,
                                    gateResult: ProposalGate.evaluate(candidate: violating, observations: world.index.observations.values.map { $0 }),
                                    now: day(2026, 11, 1, 5))
        expect(settled?.stage == .rejected, "端到端⑥违规全链：病名候选被拒")
        expect(settled?.lastReason?.contains("疾病身份") == true, "端到端⑦拒绝理由可追溯")
    }

    // MARK: M2.8 评审导出

    static func exportReviewPackage() throws {
        let world = buildWorld()
        var ledger = ShadowLedger()
        _ = ledger.register(id: "theme:猫:rev00001", themeKey: "猫", now: day(2026, 11, 1))
        _ = ledger.advance(id: "theme:猫:rev00001", to: .packaged, now: day(2026, 11, 1, 1))
        let pkg = ShadowReviewExporter.assemble(ledger: ledger, themes: world.themes, index: world.index, now: day(2026, 11, 2))
        expect(pkg.schemaVersion == 1 && pkg.candidates.count == 1, "导出①候选入包")
        expect(pkg.candidates[0].evidenceDigest.count >= 6, "导出②证据摘要随候选（无原文无数值）")
        expect(pkg.themeSummary.contains { $0.key == "猫" && $0.memberCount >= 6 }, "导出③主题摘要入包")
        let data = try ShadowReviewExporter.exportJSON(pkg)
        let text = String(data: data, encoding: .utf8) ?? ""
        expect(text.contains("\"stage\":\"packaged\""), "导出④JSON 可序列化且含阶段")
        // 字节稳定：同状态两次导出一致（评审可 diff）
        let again = try ShadowReviewExporter.exportJSON(ShadowReviewExporter.assemble(ledger: ledger, themes: world.themes, index: world.index, now: day(2026, 11, 2)))
        expect(data == again, "导出⑤同状态字节稳定（两轮评审可 diff）")
    }
}
