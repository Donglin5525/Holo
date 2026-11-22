import XCTest
@testable import Holo

// 「一个发现」v4 跨端契约测试（2026-11-20 方案 01-§5 / 04-§4）。
//
// ⚠️ 变更义务（跨端接口契约规范）：本文件字面量的真源是
// HoloBackend/src/discovery/insightGate.js（validateInsightPacket 归一化形状 +
// buildDraftEnvelope 输出形状）；改任一端必须同步另一端与本文件。
// 禁止为了让测试变绿而单方面修改字面量迁就 iOS 模型。
//
// 数字纪律样例与后端 tests/discoveryInsightGate.test.js 的 NUMBER_VECTORS
// 为同一组向量（双端一致红线：前后端数字检测共用同一组样例，两端结果一致）。
final class DiscoveryInsightContractTests: XCTestCase {

    // MARK: - 契约字面量（真源：insightGate.js + 方案总纲 §5.1/§5.2）

    /// 请求包样例：字段、枚举、嵌套形状逐字段对齐 validateInsightPacket 的归一化输出。
    private static let packetLiteral = """
    {"schemaVersion":1,"kind":"insightInput","requestId":"req-11111111","window":{"days":28},
    "portrait":[{"id":"p_xxx","dimension":"crossDomainInsight","confidence":"confirmed","statement":"想早睡","evidenceSummary":"目标原文","sourceDomains":["habit","task"]}],
    "features":[{"id":"f_xxx","domain":"finance","description":"深夜下单变少","direction":"down","slots":[{"name":"lateNightWeeks","unit":"weeks"}]}],
    "userIntents":[{"id":"u_xxx","source":"goal","text":"去标识化后的意图短句"}],
    "recentTopics":["finance-trend×coffee"],"rejectedAngles":["health-steps×weekend"]}
    """

    /// 响应样例（闸门放行后线上形状，真源：insightGate.js buildDraftEnvelope）。
    private static let draftSelectedLiteral = """
    {"schemaVersion":1,"kind":"insightDraft","selected":{"angleKey":"sleep×lateNight","headline":"早睡在顺带帮你省钱","insight":"你说想早睡的那段时间，深夜下单反而变少了，早睡好像在顺带帮你省钱。","evidence":[{"refId":"f_xxx","template":"最近{lateNightWeeks}周里深夜下单明显变少"}],"prompt":"","criteria":["D1","D2","D4"],"sourceDomains":["goal","finance"]},"noneReason":null}
    """

    private static let draftNoneLiteral = """
    {"schemaVersion":1,"kind":"insightDraft","selected":null,"noneReason":"gate_rejected"}
    """

    // MARK: - 请求包编解码

    func testPacketEncodeProducesBackendFieldNames() throws {
        let packet = InsightInputPacket(
            schemaVersion: 1,
            kind: "insightInput",
            requestId: "req-11111111",
            window: .init(days: 28),
            portrait: [.init(
                id: "p_xxx", dimension: "crossDomainInsight", confidence: "confirmed",
                statement: "想早睡", evidenceSummary: "目标原文", sourceDomains: ["habit", "task"]
            )],
            features: [.init(
                id: "f_xxx", domain: "finance", description: "深夜下单变少",
                direction: "down", slots: [.init(name: "lateNightWeeks", unit: "weeks")]
            )],
            userIntents: [.init(id: "u_xxx", source: "goal", text: "去标识化后的意图短句")],
            recentTopics: ["finance-trend×coffee"],
            rejectedAngles: ["health-steps×weekend"]
        )
        let json = try XCTUnwrap(packet.encodeJSON())
        // 关键字段名与后端 validateInsightPacket 逐一对齐（snake/camel 混排以后端为准）。
        for key in ["schemaVersion", "kind", "requestId", "window", "portrait", "features",
                    "userIntents", "recentTopics", "rejectedAngles",
                    "lateNightWeeks", "evidenceSummary", "sourceDomains", "crossDomainInsight"] {
            XCTAssertTrue(json.contains(key), "请求包缺字段 \(key)")
        }
    }

    func testPacketLiteralDecodesIntoContract() throws {
        let data = try XCTUnwrap(Self.packetLiteral.data(using: .utf8))
        let packet = try JSONDecoder().decode(InsightInputPacket.self, from: data)
        XCTAssertEqual(packet.window.days, 28)
        XCTAssertEqual(packet.portrait.first?.dimension, "crossDomainInsight")
        XCTAssertEqual(packet.features.first?.slots.first?.name, "lateNightWeeks")
        XCTAssertEqual(packet.userIntents.first?.source, "goal")
        XCTAssertEqual(packet.rejectedAngles, ["health-steps×weekend"])
    }

    // MARK: - 响应解码

    func testDraftSelectedLiteralParses() throws {
        let draft = try InsightDraftParser.parse(from: Self.draftSelectedLiteral)
        let selected = try XCTUnwrap(draft.selected)
        XCTAssertEqual(selected.angleKey, "sleep×lateNight")
        XCTAssertEqual(selected.evidence.first?.template, "最近{lateNightWeeks}周里深夜下单明显变少")
        XCTAssertEqual(selected.criteria, ["D1", "D2", "D4"])
        XCTAssertEqual(selected.sourceDomains, ["goal", "finance"])
        XCTAssertNil(draft.noneReason)
    }

    func testDraftNoneLiteralParses() throws {
        let draft = try InsightDraftParser.parse(from: Self.draftNoneLiteral)
        XCTAssertNil(draft.selected)
        XCTAssertEqual(draft.noneReason, "gate_rejected")
    }

    func testDraftRejectsBothNull() {
        // selected 与 noneReason 二者必有其一（后端闸门保证；端上解码显式失败）。
        XCTAssertThrowsError(try InsightDraftParser.parse(
            from: "{\"schemaVersion\":1,\"kind\":\"insightDraft\",\"selected\":null,\"noneReason\":null}"
        ))
    }

    func testDraftParserToleratesFence() throws {
        let fenced = "```json\n\(Self.draftNoneLiteral)\n```"
        let draft = try InsightDraftParser.parse(from: fenced)
        XCTAssertEqual(draft.noneReason, "gate_rejected")
    }

    // MARK: - 数字纪律（与后端 NUMBER_VECTORS 同一组样例）

    func testNumberDisciplineSharedVectors() {
        // 与 HoloBackend/tests/discoveryInsightGate.test.js NUMBER_VECTORS 逐条一致。
        let vectors: [(text: String, hit: Bool)] = [
            ("最近4周你花了更多", true),
            ("最近四周你花了更多", true),
            ("两三次深夜下单", true),
            ("半个月里几乎每次", true),
            ("半夜十二点还在下单", true),
            ("大概是几分之一的原因", true),
            ("花费翻倍", false),
            ("早睡好像在顺带帮你省钱", false),
            ("断签的日子任务也更容易逾期", false),
            // 2026-11-20 实测误报修正：之/几/分 出裸字符集（「之前/几乎/部分」不再误杀）。
            ("入睡时间比之前更晚", false),
            ("几乎每次都在深夜", false),
            ("深夜下单大多与加班有关", false),
        ]
        for vector in vectors {
            XCTAssertEqual(
                InsightNumberDiscipline.containsNumerals(in: vector.text), vector.hit,
                "向量判定不一致: \(vector.text)"
            )
        }
    }

    func testAsciiNumberRuns() {
        let runs = InsightNumberDiscipline.asciiNumberRuns(in: "最近4周里，共11天，发生了9次")
        XCTAssertEqual(runs, ["4", "11", "9"])
        // 全角/中文数字不进 ASCII 提取（数字⊆槽位值比对只针对回填的阿拉伯数字）。
        XCTAssertTrue(InsightNumberDiscipline.asciiNumberRuns(in: "三周·４天").isEmpty)
    }

    // MARK: - 端侧终检（03-I3：与后端闸门互为防线）

    private func makePacket() -> InsightInputPacket {
        InsightInputPacket(
            schemaVersion: 1,
            kind: "insightInput",
            requestId: "req-t",
            window: .init(days: 28),
            portrait: [.init(
                id: "p_1", dimension: "recentState", confidence: "confirmed",
                statement: "想早睡", evidenceSummary: "", sourceDomains: ["goal"]
            )],
            features: [
                .init(id: "f_1", domain: "finance", description: "深夜下单变少",
                      direction: "down", slots: [.init(name: "lateWeeks", unit: "weeks")]),
                .init(id: "f_2", domain: "task", description: "断签与逾期重合",
                      direction: "divergent", slots: [.init(name: "overdueDays", unit: "days")]),
            ],
            userIntents: [],
            recentTopics: [],
            rejectedAngles: []
        )
    }

    private func makeSelected(
        evidence: [InsightDraft.EvidenceLine] = [.init(refId: "f_1", template: "最近{lateWeeks}周里深夜下单明显变少")]
    ) -> InsightDraft.Selected {
        InsightDraft.Selected(
            angleKey: "sleep×lateNight",
            headline: "早睡在顺带帮你省钱",
            insight: "你说想早睡的那段时间，深夜下单反而变少了，早睡好像在顺带帮你省钱。",
            evidence: evidence,
            prompt: "",
            criteria: ["D1", "D2"],
            sourceDomains: ["goal", "finance"]
        )
    }

    func testTerminalCheckAcceptsValidDraft() {
        XCTAssertNil(DiscoveryInsightTerminalCheck.validate(makeSelected(), packet: makePacket()))
    }

    func testTerminalCheckRejectsChineseNumeral() {
        var selected = makeSelected()
        selected = InsightDraft.Selected(
            angleKey: selected.angleKey, headline: "最近三周的变化",
            insight: selected.insight, evidence: selected.evidence,
            prompt: selected.prompt, criteria: selected.criteria,
            sourceDomains: selected.sourceDomains
        )
        XCTAssertEqual(
            DiscoveryInsightTerminalCheck.validate(selected, packet: makePacket()),
            .numbersInJudgement
        )
    }

    func testTerminalCheckRejectsUnknownReferenceAndForeignSlot() {
        var selected = makeSelected()
        selected = InsightDraft.Selected(
            angleKey: selected.angleKey, headline: selected.headline, insight: selected.insight,
            evidence: [.init(refId: "f_ghost", template: "无空位")],
            prompt: selected.prompt, criteria: selected.criteria,
            sourceDomains: selected.sourceDomains
        )
        XCTAssertEqual(
            DiscoveryInsightTerminalCheck.validate(selected, packet: makePacket()),
            .unknownReference("f_ghost")
        )
        selected = makeSelected()
        selected = InsightDraft.Selected(
            angleKey: selected.angleKey, headline: selected.headline, insight: selected.insight,
            evidence: [.init(refId: "f_1", template: "共{overdueDays}天逾期")],
            prompt: selected.prompt, criteria: selected.criteria,
            sourceDomains: selected.sourceDomains
        )
        XCTAssertEqual(
            DiscoveryInsightTerminalCheck.validate(selected, packet: makePacket()),
            .slotNotAllowed("overdueDays")
        )
    }

    private func makeRecoveryDefaults(now: Date) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "discovery-recovery-\(UUID())"))
        defaults.set(
            Calendar.current.startOfDay(for: now).timeIntervalSince1970,
            forKey: "holo.discovery.insight.attemptDay.v3"
        )
        return defaults
    }

    @MainActor
    func testUpgradeRecoversFromRejectedResponseAndDisplaysOnlyOneCard() throws {
        let now = Date()
        let defaults = try makeRecoveryDefaults(now: now)
        let store = DiscoveryTopicStore(defaults: defaults)
        let built = DiscoveryInsightCandidateBuilder.Output(
            packet: makePacket(), slots: SlotValueTable(values: ["f_1": ["lateWeeks": "4"]])
        )
        let malformed = InsightDraft(selected: makeSelected(evidence: [
            .init(refId: "f_1", template: "深夜下单在最近{lateWeeks}周减少"),
            .init(refId: "f_2", template: "之前有{overdueDays}天逾期，近期{over"),
        ]), noneReason: nil)

        XCTAssertTrue(store.canRequestInsight(now: now))
        XCTAssertFalse(DiscoveryInsightService.applyDraft(malformed, built: built, store: store, now: now))
        XCTAssertNil(store.todayCard(now: now))

        let reopened = DiscoveryTopicStore(defaults: defaults)
        XCTAssertTrue(reopened.canRequestInsight(now: now))
        let valid = InsightDraft(selected: makeSelected(), noneReason: nil)
        XCTAssertTrue(DiscoveryInsightService.applyDraft(valid, built: built, store: reopened, now: now))
        XCTAssertEqual(reopened.todayCard(now: now)?.title, valid.selected?.headline)
        XCTAssertEqual(reopened.todayCard(now: now)?.evidenceLines, ["最近4周里深夜下单明显变少"])
        XCTAssertFalse(reopened.canRequestInsight(now: now))
        let displayed = try XCTUnwrap(reopened.todayCard(now: now))
        XCTAssertTrue(reopened.consumeToday(displayed, now: now))
        XCTAssertNil(reopened.todayCard(now: now))
        XCTAssertFalse(reopened.canRequestInsight(now: now))
    }

    func testUpgradeKeepsExistingNoCardQuotaAndConsumptionDecisions() throws {
        let now = Date()
        let defaults = try makeRecoveryDefaults(now: now)
        let store = DiscoveryTopicStore(defaults: defaults)
        let day = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        for key in [
            "holo.discovery.insight.noneDay.v1",
            "holo.discovery.insight.quotaWallDay.v1",
            "holo.discovery.topic.lastShownDay.v1",
        ] {
            defaults.set(day, forKey: key)
            XCTAssertFalse(store.canRequestInsight(now: now), key)
            defaults.removeObject(forKey: key)
        }
    }

    @MainActor
    func testSecondInvalidResponseAndExplicitGateRejectionEndTheDay() throws {
        let now = Date()
        let store = DiscoveryTopicStore(defaults: try makeRecoveryDefaults(now: now))
        let built = DiscoveryInsightCandidateBuilder.Output(packet: makePacket(), slots: SlotValueTable())
        let requiresMissingValue = InsightDraft(selected: makeSelected(), noneReason: nil)

        XCTAssertFalse(DiscoveryInsightService.applyDraft(requiresMissingValue, built: built, store: store, now: now))
        XCTAssertTrue(store.canRequestInsight(now: now))
        XCTAssertFalse(DiscoveryInsightService.applyDraft(requiresMissingValue, built: built, store: store, now: now))
        XCTAssertFalse(store.canRequestInsight(now: now))
        XCTAssertTrue(store.canRequestInsight(now: try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: now))))

        let otherStore = DiscoveryTopicStore(defaults: try makeRecoveryDefaults(now: now))
        let rejected = InsightDraft(selected: nil, noneReason: "gate_rejected")
        XCTAssertFalse(DiscoveryInsightService.applyDraft(rejected, built: built, store: otherStore, now: now))
        XCTAssertNil(otherStore.todayCard(now: now))
        XCTAssertFalse(otherStore.canRequestInsight(now: now))
    }

    // MARK: - 2026-11-21 Plus 分层 I1

    func testDraftDecodesQuotaWhenPresent() throws {
        let raw = #"{"schemaVersion":1,"kind":"insightDraft","selected":null,"noneReason":"quota_exhausted","quota":{"used":1,"limit":1,"tier":"free","resetAt":1764224000000}}"#
        let draft = try InsightDraftParser.parse(from: raw)
        XCTAssertEqual(draft.quota?.used, 1)
        XCTAssertEqual(draft.quota?.tier, "free")
        XCTAssertEqual(draft.quota?.resetDate, Date(timeIntervalSince1970: 1_764_224_000))
    }

    func testDraftQuotaAbsentAndNullReset() throws {
        let noQuota = try InsightDraftParser.parse(from: #"{"schemaVersion":1,"selected":null,"noneReason":"none_worthwhile"}"#)
        XCTAssertNil(noQuota.quota)
        let plus = try InsightDraftParser.parse(from: #"{"schemaVersion":1,"selected":null,"noneReason":"quota_exhausted","quota":{"used":2,"limit":5,"tier":"plus","resetAt":null}}"#)
        XCTAssertNil(plus.quota?.resetDate)
    }

    func testPacketOmitsFocusWhenNilAndEncodesWhenSet() throws {
        var packet = InsightInputPacket(
            schemaVersion: 1, kind: "insightInput", requestId: "r1",
            window: .init(days: 28), portrait: [], features: [], userIntents: [],
            recentTopics: [], rejectedAngles: []
        )
        XCTAssertFalse(packet.encodeJSON()?.contains("focusFeatureIds") ?? true)
        packet.focusFeatureIds = ["f_anomaly_0"]
        XCTAssertTrue(packet.encodeJSON()?.contains(#""focusFeatureIds":["f_anomaly_0"]"#) ?? false)
    }
}
