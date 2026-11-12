//
//  EvidenceRouterStandaloneTests.swift
//  Holo
//
//  M2.3 取证路由单测：能力目录判定 / 三 op 真实现 / 失败类型化（不降级为空）。
//

import Foundation

// 入口在 UnderstandingStandaloneRunner.swift。

struct EvidenceRouterStandaloneTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func run() throws {
        testCapabilityGate()
        testRetrieveRelated()
        testCheckOwnership()
        testComparePeriods()
        testFailureTyping()

        print("EvidenceRouterStandaloneTests: \(assertions) assertions passed")
    }

    // MARK: 夹具

    static let calendar = { () -> Calendar in
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()
    static func day(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// 真实投影生成财务观察（概念/归属/时间走 FinanceObservationProjector 真路径）。
    static func makeIndex() -> ObservationIndex {
        var index = ObservationIndex()
        _ = index.merge(FinanceObservationProjector.project([
            FinanceObservationInput(id: "cat-1", note: "猫粮", occurredAt: day(2026, 8, 14, 19, 32), recordedAt: day(2026, 8, 14, 19, 35), updatedAt: day(2026, 8, 14, 19, 35), isRefund: false, categoryName: "宠物用品"),
            FinanceObservationInput(id: "cat-2", note: "猫粮 5kg", occurredAt: day(2026, 9, 2, 20, 10), recordedAt: day(2026, 9, 2, 20, 12), updatedAt: day(2026, 9, 2, 20, 12), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-3", note: "猫砂豆腐砂", occurredAt: day(2026, 9, 25, 12, 47), recordedAt: day(2026, 9, 25, 12, 50), updatedAt: day(2026, 9, 25, 12, 50), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-4", note: "猫粮 帮王阿姨带的", occurredAt: day(2026, 10, 11, 19, 5), recordedAt: day(2026, 10, 11, 19, 6), updatedAt: day(2026, 10, 11, 19, 6), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "coffee-1", note: "咖啡", occurredAt: day(2026, 9, 8, 14, 22), recordedAt: day(2026, 9, 8, 14, 23), updatedAt: day(2026, 9, 8, 14, 23), isRefund: false, categoryName: nil),
        ]))
        _ = index.merge(ThoughtObservationProjector.project([
            ThoughtObservationInput(id: "th-1", text: "猫最近掉毛厉害，查一下是不是该换粮了。", createdAt: day(2026, 10, 12, 8, 20), updatedAt: day(2026, 10, 12, 8, 20), isAIDerived: false),
            ThoughtObservationInput(id: "th-2", text: "每周摘要：本周购买猫粮一次", createdAt: day(2026, 10, 13, 8, 0), updatedAt: day(2026, 10, 13, 8, 0), isAIDerived: true),
        ]))
        _ = index.merge([
            LifeObservation(domain: .task, sourceRef: "task-1", sourceRevision: "r1", sourceKind: "todo",
                            occurredAt: day(2026, 9, 6, 9, 40), recordedAt: day(2026, 9, 6, 9, 41),
                            timePrecision: .minute, concepts: ["打扫猫砂盆"], action: "照料",
                            attribution: .self_, businessState: .done, coverage: nil, quote: "打扫猫砂盆 已完成"),
        ])
        return index
    }

    static var router: EvidenceRouter { EvidenceRouter(index: makeIndex()) }

    // MARK: 1. 能力闸

    static func testCapabilityGate() {
        let goalRequest = EvidenceRequest(op: .retrieveRelated, domain: .goal, concepts: ["目标"])
        if case .capabilityUnavailable(let domain, let op)? = router.execute(goalRequest).failure {
            expect(domain == .goal && op == .retrieveRelated, "未登记域→capabilityUnavailable 且带域与操作")
        } else {
            fatalError("未登记域必须失败而非空结果")
        }
        let healthRequest = EvidenceRequest(op: .comparePeriods, domain: .health, concepts: ["活动分钟"])
        if case .capabilityUnavailable? = router.execute(healthRequest).failure {
            expect(true, "健康域样板期未登记 comparePeriods → capabilityUnavailable（不放水）")
        } else {
            fatalError("未登记操作必须失败")
        }
    }

    // MARK: 2. retrieveRelated（跨域召回 + derived 排除 + limit）

    static func testRetrieveRelated() {
        let request = EvidenceRequest(op: .retrieveRelated, domain: .finance, concepts: ["猫粮"], limit: 10)
        let result = router.execute(request)
        let related = result.payload?.relatedObservations ?? []
        expect(related.count == 3, "猫粮概念召回 3 条（含猫粮/猫粮5kg/帮王阿姨带的猫粮），实际 \(related.count)")
        expect(related.contains { $0.sourceRef == "th-2" } == false, "AI 派生摘要(th-2)不作独立证据被召回")
        // 跨域：thought 原话 concepts 为空（概念提取归主题层），此处仅验证不崩且 finance/task 命中
        expect(related.allSatisfy { $0.domain == .finance }, "财务域概念召回先出财务观察")
        let empty = router.execute(EvidenceRequest(op: .retrieveRelated, domain: .finance, concepts: ["不存在的概念"]))
        if case .insufficientEvidence? = empty.failure {
            expect(true, "无同概念材料→insufficientEvidence（明示，不返回空数组冒充结果）")
        } else {
            fatalError("无材料必须是显式失败")
        }
    }

    // MARK: 3. checkOwnership

    static func testCheckOwnership() {
        let mixed = router.execute(EvidenceRequest(op: .checkOwnership, domain: .finance,
                                                   sourceRefs: ["cat-1", "cat-4", "th-1"]))
        let summary = mixed.payload?.ownership
        expect(summary?.selfEvidenced.contains("th-1") == true, "用户原话计入本人证据")
        expect(summary?.proxyEvidenced.contains("cat-4") == true, "『帮王阿姨带的』计入代办证据")
        expect(summary?.unknown.contains("cat-1") == true, "无归属线索的账单归 unknown，不默认本人")
        expect(summary?.verdict == "mixed", "本人+代办并存→mixed")

        let proxyOnly = router.execute(EvidenceRequest(op: .checkOwnership, domain: .finance, sourceRefs: ["cat-4"]))
        expect(proxyOnly.payload?.ownership?.verdict == "proxy", "纯代办证据→proxy（M1.6 代购拆台的本机取证）")
    }

    // MARK: 4. comparePeriods（频次比较）

    static func testComparePeriods() {
        // 基线窗 8-01~8-31（猫粮1笔/31天≈0.032/天）vs 当前窗 9-01~10-15（猫粮2笔/45天…cat-2,cat-4）
        let request = EvidenceRequest(op: .comparePeriods, domain: .finance, concepts: ["猫粮"],
                                      baselineWindow: DateInterval(start: day(2026, 8, 1), end: day(2026, 8, 31, 23, 59)),
                                      currentWindow: DateInterval(start: day(2026, 9, 1), end: day(2026, 10, 15, 23, 59)))
        guard let comparison = router.execute(request).payload?.comparison else { fatalError("频次比较应有结果") }
        expect(comparison.baselineCount == 1 && comparison.currentCount == 2, "两窗口计数正确")
        expect(comparison.baselineDays == 31 && comparison.currentDays == 45, "窗口天数正确")
        expect(comparison.direction == "up", "日均率上升→up（程序判定，模型不得改值）")

        let invalid = router.execute(EvidenceRequest(op: .comparePeriods, domain: .finance, concepts: ["猫粮"]))
        if case .invalidRequest? = invalid.failure {
            expect(true, "缺窗口参数→invalidRequest")
        } else {
            fatalError("缺参数必须显式失败")
        }
    }

    // MARK: 5. 失败不降级为空

    static func testFailureTyping() {
        let failed = router.execute(EvidenceRequest(op: .checkCoverage, domain: .finance))
        expect(failed.payload == nil && failed.failure != nil,
               "失败结果 payload 必须为 nil（禁止失败伪装成空成功——M1.2『查过的范围』教训）")
    }
}
