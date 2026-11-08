import XCTest
@testable import Holo

/// v3「一个发现」选题客户端测试（2026-11-08 方案 §5.2/§5.3）：
/// 空位回填终审（残留/长度/外来数字）、槽位真值解析、形状组装过滤、
/// 展示队列（每日一张/否定/冷却/时效）、本机降级规则。
@MainActor
final class DiscoveryTopicServiceTests: XCTestCase {

    private var store: DiscoveryTopicStore!

    override func setUp() async throws {
        // 独立 defaults suite，测试间互不污染。
        let name = "discovery-topic-tests-\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: name)
        store = DiscoveryTopicStore(defaults: UserDefaults(suiteName: name)!)
    }

    // MARK: - 测试数据（真实挖掘器提案）

    private func financeProposals(dayOffsets: [Int]) -> [HoloKnowledgeRevision] {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        // 挖掘器取数窗为 8 周（前 4 周做变化对照基线），测试窗须与之一致。
        let window = DateInterval(start: cal.date(byAdding: .day, value: -56, to: now)!, end: now)
        let input = dayOffsets.enumerated().map { idx, off in
            FinanceMemoryTransactionInput(
                id: "tx-\(idx)", amount: 25, isExpense: true,
                categoryID: "cat-dinner", categoryName: "晚餐",
                merchant: nil,
                occurredAt: cal.date(bySettingHour: 12, minute: 0, second: 0, of: cal.date(byAdding: .day, value: -off, to: now)!)!,
                revisionDigest: "rev-\(idx)"
            )
        }
        return HoloRecordedPatternMiner.finance(input, window: window, calendar: cal)
    }

    // MARK: - 形状组装

    func test_candidatesAssembleFromMinerProposals() {
        let proposals = financeProposals(dayOffsets: [1, 2, 3, 5, 8, 12, 20, 26, 31, 35])
        let pool = DiscoveryTopicService.candidates(from: proposals)
        guard let c = pool.first else {
            return XCTFail("挖掘器合格提案应组装出候选")
        }
        XCTAssertEqual(c.domain, "finance")
        XCTAssertEqual(c.kind, "windowChange")
        XCTAssertEqual(c.label, "晚餐")
        XCTAssertTrue(c.slots.contains("weeks"))
        XCTAssertTrue(c.slots.contains("recentCount"))
        XCTAssertFalse(c.id.contains("|"), "形状摘要不得携带 measured 真值")
    }

    // MARK: - 回填终审

    private func makeSelection(title: String, body: String, pool: [DiscoveryTopicCandidate]) -> DiscoveryTopicSelection {
        DiscoveryTopicSelection(
            observationId: pool.first!.id,
            angle: "contrast", reasonCode: "recent_change",
            titleTemplate: title, bodyTemplate: body
        )
    }

    func test_buildCardFillsSlotsWithRealValues() throws {
        let proposals = financeProposals(dayOffsets: [1, 2, 3, 5, 8, 12, 20, 26, 31, 35])
        let pool = DiscoveryTopicService.candidates(from: proposals)
        // 8 周窗数据命中 windowChange（变化类优先于频次），槽位按该类型可用集合写。
        let selection = makeSelection(
            title: "你的{label}，变多了",
            body: "最近{weeks}周记了{recentCount}笔，比上一个{weeks}周多了{absDelta}笔。",
            pool: pool
        )
        let card = try DiscoveryTopicService.buildCard(selection: selection, pool: pool, proposals: proposals)
        XCTAssertFalse(card.title.contains("{"))
        XCTAssertFalse(card.body.contains("{"))
        XCTAssertTrue(card.body.contains("8"), "回填真实 recentCount")
        XCTAssertTrue(card.isModelCopy)
    }

    func test_buildCardRejectsResidualSlot() {
        let proposals = financeProposals(dayOffsets: [1, 2, 3, 5, 8, 12, 20, 26, 31, 35])
        let pool = DiscoveryTopicService.candidates(from: proposals)
        let selection = makeSelection(title: "未知值{nonexistent}", body: "最近{weeks}周有记录。", pool: pool)
        XCTAssertThrowsError(try DiscoveryTopicService.buildCard(selection: selection, pool: pool, proposals: proposals))
    }

    func test_buildCardRejectsForeignNumber() {
        let proposals = financeProposals(dayOffsets: [1, 2, 3, 5, 8, 12, 20, 26, 31, 35])
        let pool = DiscoveryTopicService.candidates(from: proposals)
        // 「2倍」是模型自己估的比例——槽位值里没有，必须拒（阿拉伯数字严格校验）。
        let selection = makeSelection(title: "晚餐开销变多", body: "最近{weeks}周里这类支出差不多翻了3倍。", pool: pool)
        XCTAssertThrowsError(try DiscoveryTopicService.buildCard(selection: selection, pool: pool, proposals: proposals)) { error in
            XCTAssertEqual(error as? DiscoveryTopicService.TopicError, .foreignNumber)
        }
    }

    // MARK: - 数字纪律提取

    func test_extractNumbersCatchesArabicOnly() {
        // 中文数字豁免（「一个」误杀真机实证）：只抓阿拉伯数字。
        let nums = DiscoveryTopicService.extractNumbers(from: "最近4周里 共十一天 两次翻2倍")
        XCTAssertTrue(nums.contains("4"))
        XCTAssertTrue(nums.contains("2"))
        XCTAssertFalse(nums.contains { $0.contains("十") || $0.contains("两") || $0.contains("一") })
    }

    // MARK: - 本机降级

    func test_localFallbackUsesMinerTextWithoutModelBadge() {
        let proposals = financeProposals(dayOffsets: [1, 2, 3, 5, 8, 12, 20, 26, 31, 35])
        let pool = DiscoveryTopicService.candidates(from: proposals)
        let card = DiscoveryTopicService.localFallback(pool: pool, proposals: proposals, now: Date())
        XCTAssertNotNil(card)
        XCTAssertEqual(card?.isModelCopy, false, "降级卡不带 AI 精选标识")
        XCTAssertFalse(card!.body.isEmpty)
    }

    // MARK: - 展示队列（每日一张）

    private func card(_ topicKey: String, windowEnd: Date? = nil) -> DiscoveryTopicStore.QueuedCard {
        DiscoveryTopicStore.QueuedCard(
            observationId: "obs-\(topicKey)", topicKey: topicKey,
            title: "t", body: "b", isModelCopy: true,
            selectedAt: Date(), windowEnd: windowEnd ?? Date().addingTimeInterval(86_400)
        )
    }

    func test_queueDailyConsumeAndReveal() {
        store.enqueue(card("k1"))
        store.enqueue(card("k2"))
        XCTAssertTrue(store.shouldRevealToday())
        XCTAssertNotNil(store.todayCard())
        store.consumeToday()
        XCTAssertFalse(store.shouldRevealToday(), "每天一张：消费后当日不再出")
        XCTAssertTrue(store.consumedToday())
        XCTAssertFalse(store.queue.isEmpty, "存起来的卡留给后面几天")
        XCTAssertTrue(store.shownTopics.contains("k1"))
    }

    func test_todayCardGatedPerNaturalDay() {
        // 东林拍板「每天最多一张」：队列有存量时，当天消费后 todayCard 必须为 nil
        //（胶囊不再亮、评审页不再换下一张），次日自然日才放行下一张。
        let cal = Calendar(identifier: .gregorian)
        let day1 = cal.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        store.enqueue(card("k1"))
        store.enqueue(card("k2"))
        XCTAssertEqual(store.todayCard(now: day1, calendar: cal)?.topicKey, "k1")
        store.consumeToday(now: day1, calendar: cal)
        XCTAssertNil(store.todayCard(now: day1.addingTimeInterval(3600), calendar: cal),
                     "当天消费过：即使队列还有下一张也不出")
        let day2 = day1.addingTimeInterval(86_400)
        XCTAssertEqual(store.todayCard(now: day2, calendar: cal)?.topicKey, "k2",
                       "次日放行下一张")
    }

    func test_queueSkipsRejectedAndExpired() {
        store.enqueue(card("rejected-key"))
        store.markRejected("rejected-key")
        XCTAssertNil(store.todayCard(), "否定命题的卡即时撤下")
        store.enqueue(card("expired-key", windowEnd: Date().addingTimeInterval(-1)))
        XCTAssertNil(store.todayCard(), "过期卡跳过")
        store.enqueue(card("live-key"))
        XCTAssertEqual(store.todayCard()?.topicKey, "live-key")
    }

    func test_deferredCooldownExpires() {
        store.markDeferred("cool-key", now: Date().addingTimeInterval(-8 * 86_400))
        XCTAssertTrue(store.deferredActiveKeys().isEmpty, "超过冷却期回池")
        store.markDeferred("cooling-key")
        XCTAssertTrue(store.deferredActiveKeys().contains("cooling-key"))
    }

    // MARK: - 契约形状（与服务端响应逐字段对拍）

    func test_responseDecodesServerShape() throws {
        let json = """
        {"protocolVersion":1,"status":"completed","selection":{"observationId":"obs-7","angle":"contrast","reasonCode":"recent_change","titleTemplate":"工作日的{label}，悄悄变贵了","bodyTemplate":"最近{weeks}周里，有{matchWeeks}周你工作日的{label}日均花销高于同周周末。"},"noneReason":null,"promptVersion":1,"requestId":"req-1"}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(DiscoveryTopicResponse.self, from: json)
        XCTAssertEqual(response.protocolVersion, 1)
        XCTAssertEqual(response.selection?.observationId, "obs-7")
        XCTAssertEqual(response.selection?.titleTemplate, "工作日的{label}，悄悄变贵了")
        XCTAssertNil(response.noneReason)
    }

    func test_responseDecodesNoneShape() throws {
        let json = """
        {"protocolVersion":1,"status":"completed","selection":null,"noneReason":"none_worthwhile","degraded":true,"promptVersion":1}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(DiscoveryTopicResponse.self, from: json)
        XCTAssertNil(response.selection)
        XCTAssertEqual(response.noneReason, "none_worthwhile")
        XCTAssertEqual(response.degraded, true)
    }
}
