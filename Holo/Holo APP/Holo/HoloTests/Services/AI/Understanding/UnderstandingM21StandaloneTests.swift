//
//  UnderstandingM21StandaloneTests.swift
//  Holo
//
//  M2.1 观察索引 standalone 单测（swiftc 直编，不挂 pbxproj——挂载随 M2 集成批做）。
//  跑法：bash scripts/run-understanding-standalone.sh
//

import Foundation

// 入口在 UnderstandingStandaloneRunner.swift（两套件共用一个 @main）。

struct UnderstandingM21StandaloneTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)

        testConceptExtraction()
        testAttributionLexicon()
        testBackfillAndPrecision()
        testRefundAndBusinessState()
        testThoughtProjection()
        testIndexMergeIdempotency()
        testIndexRevisionUpdate()
        testReplaceDomainRemoval()
        testPersistenceRoundTrip()
        testCapabilityCatalog()

        print("UnderstandingM21StandaloneTests: \(assertions) assertions passed")
    }

    // MARK: 固定时钟（北京时间 2026-09-02 20:10）

    static let calendar = { () -> Calendar in
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()
    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    static func finance(
        id: String = "tx-1", note: String?, occurredAt: Date, recordedAt: Date? = nil,
        updatedAt: Date? = nil, isRefund: Bool = false, categoryName: String? = nil
    ) -> FinanceObservationInput {
        FinanceObservationInput(
            id: id, note: note, occurredAt: occurredAt,
            recordedAt: recordedAt ?? occurredAt,
            updatedAt: updatedAt ?? recordedAt ?? occurredAt,
            isRefund: isRefund, categoryName: categoryName)
    }

    // MARK: 1. 概念提取

    static func testConceptExtraction() {
        expect(FinanceObservationProjector.concepts(fromNote: "猫粮 5kg", categoryName: nil) == ["猫粮"],
               "含数字量纲的 token 应被过滤：『猫粮 5kg』→『猫粮』")
        expect(FinanceObservationProjector.concepts(fromNote: "猫砂豆腐砂", categoryName: nil) == ["猫砂豆腐砂"],
               "无空格中文整条保留（两字概念不丢弃）")
        expect(FinanceObservationProjector.concepts(fromNote: "", categoryName: "宠物用品") == ["宠物用品"],
               "空备注回退类目名")
        expect(FinanceObservationProjector.concepts(fromNote: "咖啡 外卖 睡前想喝 拿铁 美式 手冲 挂耳", categoryName: nil).count == 4,
               "概念 token 上限 4")
        expect(FinanceObservationProjector.concepts(fromNote: "宠物用品", categoryName: "宠物用品") == ["宠物用品"],
               "类目与概念重复时去重")
    }

    // MARK: 2. 归属词法

    static func testAttributionLexicon() {
        expect(FinanceObservationProjector.attribution(fromNote: "猫粮 帮楼下王阿姨带的") == .proxy, "『帮X带的』→proxy")
        expect(FinanceObservationProjector.attribution(fromNote: "猫粮 帮表姐家带的") == .proxy, "『帮表姐家带的』→proxy")
        expect(FinanceObservationProjector.attribution(fromNote: "帮王阿姨带 5kg") == .proxy, "『帮X带』→proxy")
        expect(FinanceObservationProjector.attribution(fromNote: "代购猫砂") == .proxy, "『代购』→proxy")
        expect(FinanceObservationProjector.attribution(fromNote: "猫粮 5kg") == .unknown, "普通备注归属未知，不默认本人")
        expect(FinanceObservationProjector.attribution(fromNote: "宠物医院 疫苗") == .unknown, "无代办词法→unknown")
        // 反例：帮自己买东西不算代办（无「带/买/购」承接他人语义）
        expect(FinanceObservationProjector.attribution(fromNote: "帮自己挑的生日礼物") == .unknown, "『帮自己』不误判 proxy")
    }

    // MARK: 3. 补账与时间精度

    static func testBackfillAndPrecision() {
        let backfill = FinanceObservationProjector.project([
            finance(id: "b1", note: "咖啡",
                    occurredAt: date(2026, 10, 4),               // 午夜整点默认值
                    recordedAt: date(2026, 10, 4, 22, 30))       // 当晚 22:30 记录
        ])[0]
        expect(backfill.timePrecision == .midnightDefault, "跨日+午夜整点→midnightDefault")
        expect(backfill.coverage?.kind == .batchBackfill, "补账带 coverage 标记")
        expect(backfill.concepts == ["咖啡"], "补账观察概念正常保留")

        let sameDay = FinanceObservationProjector.project([
            finance(id: "b2", note: "咖啡", occurredAt: date(2026, 9, 8, 14, 22))
        ])[0]
        expect(sameDay.timePrecision == .minute && sameDay.coverage == nil, "同日分钟级→minute 无标记")

        let crossDay = FinanceObservationProjector.project([
            finance(id: "b3", note: "咖啡", occurredAt: date(2026, 9, 8, 14, 22), recordedAt: date(2026, 9, 9, 9, 0))
        ])[0]
        expect(crossDay.timePrecision == .day, "跨日非午夜→day（发生时间可信但只知大概）")

        // 跨日补以前的账（周五的事周一记，发生时间=周五零点默认）
        let olderBackfill = FinanceObservationProjector.project([
            finance(id: "b4", note: "咖啡", occurredAt: date(2026, 10, 2), recordedAt: date(2026, 10, 5, 22, 30))
        ])[0]
        expect(olderBackfill.timePrecision == .midnightDefault && olderBackfill.coverage?.kind == .batchBackfill,
               "跨日+零点默认→midnightDefault（补以前的账）")

        // 反例：非零点整的真实时刻永不算补账默认
        expect(!FinanceObservationProjector.isBatchBackfill(
            occurredAt: date(2026, 10, 4, 0, 1), recordedAt: date(2026, 10, 4, 22, 30)),
            "零点过一分=真实记录时刻，不算默认补账")
    }

    // MARK: 4. 退款与业务状态

    static func testRefundAndBusinessState() {
        let refund = FinanceObservationProjector.project([
            finance(id: "r1", note: "猫粮", occurredAt: date(2026, 9, 8, 14, 22), isRefund: true)
        ])[0]
        expect(refund.businessState == .negation, "退款→negation（证据层不产生正向行为）")

        let normal = FinanceObservationProjector.project([
            finance(id: "r2", note: "猫粮", occurredAt: date(2026, 9, 8, 14, 22))
        ])[0]
        expect(normal.businessState == .plain && normal.action == "购买" && normal.quote == "猫粮",
               "普通购买：plain + action=购买 + 原文引用保留")
        expect(normal.isShareable, "有概念即可上送（语义视图成员）")
    }

    // MARK: 5. 想法投影

    static func testThoughtProjection() {
        let thoughts = ThoughtObservationProjector.project([
            ThoughtObservationInput(id: "t1", text: "猫最近掉毛厉害，查一下是不是该换粮了。",
                                    createdAt: date(2026, 10, 12, 8, 20), updatedAt: date(2026, 10, 12, 8, 20), isAIDerived: false),
            ThoughtObservationInput(id: "t2", text: "每周摘要：本周购买猫粮一次",
                                    createdAt: date(2026, 10, 13, 8, 0), updatedAt: date(2026, 10, 13, 8, 5), isAIDerived: true),
        ])
        expect(thoughts[0].businessState == .quote && thoughts[0].quote?.contains("掉毛") == true,
               "用户原话→quote 且全文可回查")
        expect(thoughts[1].businessState == .derived, "AI 派生→derived（不构成独立证据的标记）")
        expect(thoughts.allSatisfy { $0.attribution == .self_ }, "想法域归属=本人")
        // 稳定哈希：同文本两次摘要一致（跨进程持久化前提）
        let a = ThoughtObservationInput(id: "x", text: "同一段文字", createdAt: date(2026, 1, 1), updatedAt: date(2026, 1, 1), isAIDerived: false)
        let b = ThoughtObservationInput(id: "x", text: "同一段文字", createdAt: date(2026, 1, 1), updatedAt: date(2026, 1, 1), isAIDerived: false)
        expect(a.revisionDigest == b.revisionDigest, "稳定摘要：同文本同时间→同修订")
        expect(a.revisionDigest != ThoughtObservationInput(id: "x", text: "不同文字", createdAt: date(2026, 1, 1), updatedAt: date(2026, 1, 1), isAIDerived: false).revisionDigest,
               "稳定摘要：不同文本→不同修订")
    }

    // MARK: 6. 索引幂等

    static func testIndexMergeIdempotency() {
        let batch = FinanceObservationProjector.project([
            finance(id: "m1", note: "猫粮", occurredAt: date(2026, 8, 14, 19, 32)),
            finance(id: "m2", note: "猫砂", occurredAt: date(2026, 9, 25, 12, 47)),
        ])
        var index = ObservationIndex()
        let first = index.merge(batch)
        expect(first.added == 2 && first.updated == 0, "首批全新增")
        let second = index.merge(batch)
        expect(second.unchanged == 2 && second.isEmpty, "同批重跑零变化（幂等，不重复处理）")
    }

    // MARK: 7. 修订更新

    static func testIndexRevisionUpdate() {
        let v1 = FinanceObservationProjector.project([
            finance(id: "u1", note: "猫粮", occurredAt: date(2026, 8, 14, 19, 32), updatedAt: date(2026, 8, 14, 19, 35))
        ])
        var index = ObservationIndex()
        _ = index.merge(v1)
        let v2 = FinanceObservationProjector.project([
            finance(id: "u1", note: "猫粮 5kg", occurredAt: date(2026, 8, 14, 19, 32), updatedAt: date(2026, 9, 1, 10, 0))
        ])
        let delta = index.merge(v2)
        expect(delta.updated == 1 && index.observations.count == 1,
               "备注修订→替换而非新增（同 sourceRef 单条）")
        expect(index.observations(in: .finance)[0].quote == "猫粮 5kg", "新修订生效")
    }

    // MARK: 8. 域替换删除

    static func testReplaceDomainRemoval() {
        var index = ObservationIndex()
        _ = index.merge(FinanceObservationProjector.project([
            finance(id: "d1", note: "猫粮", occurredAt: date(2026, 8, 14, 19, 32)),
            finance(id: "d2", note: "猫砂", occurredAt: date(2026, 9, 25, 12, 47)),
        ]))
        _ = index.merge(ThoughtObservationProjector.project([
            ThoughtObservationInput(id: "t9", text: "无关想法", createdAt: date(2026, 9, 1), updatedAt: date(2026, 9, 1), isAIDerived: false),
        ]))
        // 域全量重投影：d2 来源已删除（用户删了那笔账）
        let delta = index.replaceDomain(.finance, with: FinanceObservationProjector.project([
            finance(id: "d1", note: "猫粮", occurredAt: date(2026, 8, 14, 19, 32)),
        ]))
        expect(delta.removed == 1, "来源删除→条目移除（失效扇出）")
        expect(index.observations(in: .finance).count == 1, "财务域只剩存活的来源")
        expect(index.observations(in: .thought).count == 1, "替换不影响他域")
    }

    // MARK: 9. 持久化往返

    static func testPersistenceRoundTrip() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("understanding-index-test-\(UUID().uuidString)")
        var index = ObservationIndex()
        _ = index.merge(FinanceObservationProjector.project([
            finance(id: "p1", note: "猫粮 帮邻居带的", occurredAt: date(2026, 8, 14, 19, 32)),
        ]))
        try! index.save(to: dir)
        let loaded = ObservationIndex.load(directory: dir)
        expect(loaded == index, "save/load 往返相等")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: 10. 能力目录

    static func testCapabilityCatalog() {
        expect(DomainCapabilityCatalog.capability(for: .finance)?.supports(.checkOwnership) == true,
               "财务域支持归属查证")
        expect(DomainCapabilityCatalog.capability(for: .health)?.supports(.comparePeriods) == false,
               "健康域样板期未登记 op → 不支持（不放水）")
        expect(DomainCapabilityCatalog.capability(for: .goal) == nil,
               "未登记域返回 nil（路由层转 capabilityUnavailable）")
        expect(DomainCapabilityCatalog.finance.timePrecision == .minute, "财务域时间精度登记")
    }
}
