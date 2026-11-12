//
//  ThemeIndexStandaloneTests.swift
//  Holo
//
//  M2.2 主题包单测：M1.1 caseA 等价断言（施工图验收）/ 归并规则 / 指纹与变化检测。
//

import Foundation

// 入口在 UnderstandingStandaloneRunner.swift。

struct ThemeIndexStandaloneTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func run() throws {
        testCaseAEquivalence()
        testMergeRules()
        testFingerprintStability()
        testChangeDetection()

        print("ThemeIndexStandaloneTests: \(assertions) assertions passed")
    }

    static let calendar = { () -> Calendar in
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()
    static func day(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    /// M1.1 caseA-normal 全量输入（财务 5 笔 + 想法 2 条 + 任务 1 条，走真实投影）。
    static func caseAObservations() -> [LifeObservation] {
        var all = FinanceObservationProjector.project([
            FinanceObservationInput(id: "cat-1", note: "猫粮", occurredAt: day(2026, 8, 14, 19), recordedAt: day(2026, 8, 14, 19), updatedAt: day(2026, 8, 14, 19), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-2", note: "猫粮 5kg", occurredAt: day(2026, 9, 2, 20), recordedAt: day(2026, 9, 2, 20), updatedAt: day(2026, 9, 2, 20), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-3", note: "猫砂豆腐砂", occurredAt: day(2026, 9, 25, 12), recordedAt: day(2026, 9, 25, 12), updatedAt: day(2026, 9, 25, 12), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "cat-4", note: "猫粮", occurredAt: day(2026, 10, 11, 19), recordedAt: day(2026, 10, 11, 19), updatedAt: day(2026, 10, 11, 19), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "pet-1", note: "宠物医院 疫苗", occurredAt: day(2026, 10, 19, 15), recordedAt: day(2026, 10, 19, 15), updatedAt: day(2026, 10, 19, 15), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "coffee-1", note: "咖啡", occurredAt: day(2026, 9, 8, 14), recordedAt: day(2026, 9, 8, 14), updatedAt: day(2026, 9, 8, 14), isRefund: false, categoryName: nil),
        ])
        all += ThoughtObservationProjector.project([
            ThoughtObservationInput(id: "th-1", text: "今晚加班回家，猫在门口等我。", createdAt: day(2026, 9, 26, 23), updatedAt: day(2026, 9, 26, 23), isAIDerived: false),
            ThoughtObservationInput(id: "th-2", text: "猫最近掉毛厉害，查一下是不是该换粮了。", createdAt: day(2026, 10, 12, 8), updatedAt: day(2026, 10, 12, 8), isAIDerived: false),
        ])
        all += [
            LifeObservation(domain: .task, sourceRef: "task-1", sourceRevision: "r1", sourceKind: "todo",
                            occurredAt: day(2026, 9, 6, 9), recordedAt: day(2026, 9, 6, 9),
                            timePrecision: .minute, concepts: ["猫砂盆"], action: "照料",
                            attribution: .self_, businessState: .done, coverage: nil, quote: "打扫猫砂盆"),
        ]
        return all
    }

    // MARK: 1. caseA 等价（施工图 M2.1-2 验收断言）

    static func testCaseAEquivalence() {
        let themes = ThemeIndex.buildThemes(from: caseAObservations())
        let catTheme = themes.first { $0.concepts.contains("猫粮") }
        expect(catTheme != nil, "猫主题聚出（猫粮/猫砂簇）")
        expect(catTheme!.isCrossDomain, "猫主题跨域（finance+task+thought）")
        expect(catTheme!.memberIDs.contains { $0.contains("th-") }, "想法原话入簇（『猫在门口等我』锚词命中）")
        expect(catTheme!.memberIDs.count >= 6, "猫主题成员≥6（4财务+1任务+想法），实际 \(catTheme!.memberIDs.count)")
        let coffeeTheme = themes.first { $0.concepts.contains("咖啡") }
        expect(coffeeTheme == nil, "单条咖啡不成主题（≥2 成员过滤）")
    }

    // MARK: 2. 两级锚连通行为

    static func testMergeRules() {
        // 猫粮/猫砂靠强单字锚「猫」（挂≥2概念）连通成同主题
        let cat = ThemeIndex.buildThemes(from: caseAObservations()).first { $0.concepts.contains("猫粮") }
        expect(cat?.concepts.contains("猫砂豆腐砂") == true && cat?.concepts.contains("猫砂盆") == true,
               "猫粮/猫砂/猫砂盆经首字锚连通同簇")
        expect(cat?.key == "猫", "主题身份=稳定强锚（成员增减不漂移，工程稿§6.1）")
        // 弱锚不扫原话：单字锚直接扫原话不允许
        expect(!ThemeIndex.containsAnchor(quote: "今晚喝了一杯", anchor: "咖"), "单字锚不直接扫原话")
    }

    // MARK: 3. 指纹稳定

    static func testFingerprintStability() {
        let a = ThemeIndex.buildThemes(from: caseAObservations())
        let b = ThemeIndex.buildThemes(from: caseAObservations())
        expect(a == b, "同输入重建主题完全一致（幂等，指纹稳定）")
        // 输入顺序无关
        let shuffled = caseAObservations().reversed()
        expect(ThemeIndex.buildThemes(from: Array(shuffled)).map(\.fingerprint).sorted()
               == a.map(\.fingerprint).sorted(), "输入顺序无关（排序稳定）")
    }

    // MARK: 4. 变化检测

    static func testChangeDetection() {
        var before = ThemeIndex.buildThemes(from: caseAObservations())
        // 新增一笔猫砂 → 猫主题 updated；咖啡新增两笔 → 新主题 added
        var after = caseAObservations()
        after += FinanceObservationProjector.project([
            FinanceObservationInput(id: "cat-5", note: "猫砂", occurredAt: day(2026, 11, 1, 10), recordedAt: day(2026, 11, 1, 10), updatedAt: day(2026, 11, 1, 10), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "coffee-2", note: "咖啡", occurredAt: day(2026, 11, 2, 9), recordedAt: day(2026, 11, 2, 9), updatedAt: day(2026, 11, 2, 9), isRefund: false, categoryName: nil),
            FinanceObservationInput(id: "coffee-3", note: "咖啡", occurredAt: day(2026, 11, 3, 9), recordedAt: day(2026, 11, 3, 9), updatedAt: day(2026, 11, 3, 9), isRefund: false, categoryName: nil),
        ])
        let changes = ThemeIndex.detectChanges(old: before, new: ThemeIndex.buildThemes(from: after))
        let catChange = changes.first { $0.key.contains("猫") }
        expect(catChange?.kind == .updated, "猫主题成员变化→updated（触发行为理解通道）")
        expect(changes.contains { $0.kind == .added && $0.key == "咖啡" }, "咖啡凑满2条→新主题 added")
        // 未变化重建：全部 unchanged
        let noChange = ThemeIndex.detectChanges(old: before, new: ThemeIndex.buildThemes(from: caseAObservations()))
        expect(noChange.allSatisfy { $0.kind == .unchanged }, "同输入重建→全部 unchanged（预算保护：不重复处理）")
        before = []
    }
}
