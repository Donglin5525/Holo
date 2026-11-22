import XCTest
@testable import Holo

// 「一个发现」v4 构建器单测（2026-11-20 方案 03-I2/I4/I5/I7）。
// 覆盖：候选构建去标识化/截断/黑名单过滤/数据不足判定、CardBuilder 回填与终检、
// TopicStore v4 扩展（每日一条 v4 优先 + 角度记忆 + 当日标记）、FeedbackBridge 三种反馈。
final class DiscoveryInsightBuilderTests: XCTestCase {

    // MARK: - 夹具

    private func makePortraitStore(entryCount: Int = 2) -> PortraitStore {
        var store = PortraitStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<entryCount {
            let key = "p_\(index)"
            store.entries[key] = PortraitEntry(
                key: key,
                dimension: index % 2 == 0 ? .recentState : .crossDomainInsight,
                confidence: index % 3 == 0 ? .confirmed : .inferred,
                statement: "画像陈述\(index)",
                evidenceSummary: "证据",
                sourceDomains: ["habit"],
                usageHint: "",
                updatedAt: base.addingTimeInterval(TimeInterval(index) * 60),
                isUserConfirmed: index % 3 == 0
            )
        }
        // needsClarification 条目：应被候选构建排除。
        store.entries["p_clarify"] = PortraitEntry(
            key: "p_clarify", dimension: .preference, confidence: .needsClarification,
            statement: "待澄清", evidenceSummary: "", sourceDomains: [],
            usageHint: "", updatedAt: base, isUserConfirmed: false
        )
        return store
    }

    private func makeFeaturePacket() -> CrossDomainFeaturePacket {
        CrossDomainFeaturePacket(
            schemaVersion: 1,
            generatedAtISO: "2026-11-20T10:00:00Z",
            finance: FinanceFeatureSummary(
                windowDays: 180, totalTransactions: 42, excludedProxyOrOrgCount: 0,
                recurringConcepts: [
                    FinanceConceptFeature(
                        concept: "猫粮", count: 6, spanDays: 90, recent30dCount: 3,
                        timeOfDay: nil, dominantBand: "深夜"
                    ),
                ]
            ),
            health: HealthFeatureSummary(
                sleep: SleepFeatureSummary(
                    coverage: .good, recentDaysWithData: 12, recentWindowDays: 14,
                    recentAvgHours: 6.2, baselineAvgHours: 7.1, durationDeltaMinutes: -54,
                    recentAvgBedtimeHHMM: "00:40", baselineAvgBedtimeHHMM: "23:35",
                    bedtimeShiftMinutes: 65, lateSleepRatio: 0.7, shortSleepRatio: 0.6
                ),
                activity: ActivityFeatureSummary(
                    coverage: .good, recentDaysWithData: 13, recentWindowDays: 14,
                    recentAvgSteps: 4200, baselineAvgSteps: 6100,
                    stepsChangePercent: -31, recentAvgActiveMinutes: 25,
                    baselineAvgActiveMinutes: 40, activeMinutesChangePercent: -37
                )
            ),
            habits: HabitFeatureSummary(
                checkins: [
                    CheckinHabitTrend(name: "冥想", recent21dCount: 4, baseline21dCount: 15, total90dCount: 40, direction: "down"),
                    CheckinHabitTrend(name: "读书", recent21dCount: 6, baseline21dCount: 6, total90dCount: 30, direction: "flat"),
                ],
                numerics: [
                    NumericHabitTrend(name: "咖啡", unit: "杯", sampleCount: 9, spanDays: 30,
                                      earliestAvg: 1.0, recentAvg: 2.5, delta: 1.5, direction: "up"),
                ]
            ),
            thoughts: [ThoughtExcerptFeature(daysAgo: 2, excerpt: "想把作息调回来，最近太累了")],
            recentTasks: ["整理房间"],
            activeGoals: [GoalFeatureItem(title: "早睡计划", status: "active", desiredOutcome: "十二点前入睡")],
            profileSummary: nil,
            confirmedLegacyMemories: [],
            anomalies: [
                CrossDomainAnomalySignal(code: "sleep_later", domain: "health", summary: "近14天平均入睡较基线推迟约65分钟"),
                CrossDomainAnomalySignal(code: "numeric_habit_up", domain: "habit", summary: "数值习惯「咖啡」近30天变化+1.5杯"),
            ]
        )
    }

    private func makeMinerProposal() -> HoloKnowledgeRevision {
        let semantic = HoloKnowledgeSemantic(
            subjectRef: "self",
            objectRef: "finance-category:DINNER-CAT",
            relation: "records",
            objectValue: "11|4|9",
            dimension: "finance",
            formation: .behavioralInference,
            evidenceForm: .independentEventSet,
            displayText: "最近4周里你记录晚餐的周数高于之前",
            aiUseText: "晚餐记录频率上升"
        )
        return HoloKnowledgeRevision.make(
            semantic: semantic,
            topicLabel: "晚餐",
            domains: [.finance],
            sensitivity: .normal,
            partition: .normal,
            evidenceSnapshot: HoloKnowledgeEvidenceSnapshot(capturedAt: Date()),
            createdAt: Date()
        )
    }

    // MARK: - CandidateBuilder

    func testCandidateBuilderDeidentifiesDescriptions() throws {
        let output = try XCTUnwrap(DiscoveryInsightCandidateBuilder.build(
            portraitStore: makePortraitStore(),
            featurePacket: makeFeaturePacket(),
            proposals: [makeMinerProposal()],
            recentTopics: [],
            rejectedAngles: []
        ))
        for feature in output.packet.features {
            XCTAssertFalse(
                InsightNumberDiscipline.containsNumerals(in: feature.description),
                "特征描述含数字: \(feature.description)"
            )
        }
        for intent in output.packet.userIntents {
            XCTAssertFalse(
                InsightNumberDiscipline.containsNumerals(in: intent.text),
                "意图短句含数字: \(intent.text)"
            )
        }
    }

    func testCandidateBuilderSlotTableMatchesPacket() throws {
        let output = try XCTUnwrap(DiscoveryInsightCandidateBuilder.build(
            portraitStore: makePortraitStore(),
            featurePacket: makeFeaturePacket(),
            proposals: [makeMinerProposal()],
            recentTopics: [],
            rejectedAngles: []
        ))
        // 睡眠偏晚异常的槽位真值：v3 挖掘器口径之外的蒸馏包字段直接来自本机。
        let sleepFeature = try XCTUnwrap(output.packet.features.first { $0.description.contains("入睡时间") })
        XCTAssertEqual(output.slots.slotValues(for: sleepFeature.id)["shiftMinutes"], "65")
        // 挖掘器提案槽位（与 v3 slotValues 同口径：days|weeks|items）。
        let minerFeature = try XCTUnwrap(output.packet.features.first { $0.description.contains("晚餐") })
        let values = output.slots.slotValues(for: minerFeature.id)
        XCTAssertEqual(values["recordDays"], "11")
        XCTAssertEqual(values["weeks"], "4")
        XCTAssertEqual(values["txCount"], "9")
    }

    func testCandidateBuilderExcludesNeedsClarificationAndTruncatesPortrait() throws {
        var store = makePortraitStore(entryCount: 13)
        // 13 条有效画像 + 1 条待澄清 → 截断为 12，且不含待澄清条目。
        let output = try XCTUnwrap(DiscoveryInsightCandidateBuilder.build(
            portraitStore: store,
            featurePacket: makeFeaturePacket(),
            proposals: [],
            recentTopics: [],
            rejectedAngles: []
        ))
        XCTAssertEqual(output.packet.portrait.count, InsightInputPacket.portraitLimit)
        XCTAssertFalse(output.packet.portrait.contains { $0.id == "p_clarify" })

        // 黑名单条目：reject() 已将其移出 entries —— 构建结果同样不含。
        store.reject(key: "p_0", reason: nil, now: Date())
        let output2 = try XCTUnwrap(DiscoveryInsightCandidateBuilder.build(
            portraitStore: store,
            featurePacket: makeFeaturePacket(),
            proposals: [],
            recentTopics: [],
            rejectedAngles: []
        ))
        XCTAssertFalse(output2.packet.portrait.contains { $0.id == "p_0" })
    }

    func testCandidateBuilderInsufficientDataReturnsNil() {
        // 画像 1 条 + 特征 0 条 < 3 → 不请求（走 v3）。
        var packet = makeFeaturePacket()
        packet.habits = HabitFeatureSummary(checkins: [], numerics: [])
        packet.anomalies = []
        packet.finance.recurringConcepts = []
        packet.health = HealthFeatureSummary(
            sleep: SleepFeatureSummary(
                coverage: .none, recentDaysWithData: 0, recentWindowDays: 14,
                recentAvgHours: nil, baselineAvgHours: nil, durationDeltaMinutes: nil,
                recentAvgBedtimeHHMM: nil, baselineAvgBedtimeHHMM: nil,
                bedtimeShiftMinutes: nil, lateSleepRatio: nil, shortSleepRatio: nil
            ),
            activity: ActivityFeatureSummary(
                coverage: .none, recentDaysWithData: 0, recentWindowDays: 14,
                recentAvgSteps: nil, baselineAvgSteps: nil, stepsChangePercent: nil,
                recentAvgActiveMinutes: nil, baselineAvgActiveMinutes: nil,
                activeMinutesChangePercent: nil
            )
        )
        let output = DiscoveryInsightCandidateBuilder.build(
            portraitStore: makePortraitStore(entryCount: 1),
            featurePacket: packet,
            proposals: [],
            recentTopics: [],
            rejectedAngles: []
        )
        XCTAssertNil(output)
    }

    // MARK: - CardBuilder

    private func makeDraftSelected() -> InsightDraft.Selected {
        InsightDraft.Selected(
            angleKey: "sleep×lateNight",
            headline: "早睡在顺带帮你省钱",
            insight: "你说想早睡的那段时间，深夜下单反而变少了，早睡好像在顺带帮你省钱。",
            evidence: [
                .init(refId: "f_1", template: "最近{weeks}周里深夜下单共{totalCount}次、变少"),
                .init(refId: "f_2", template: "断签那几天任务逾期共{overdueDays}天"),
                .init(refId: "f_missing", template: "缺值行 {ghostSlot} 不应出现"),
            ],
            prompt: "要不要看看这阵子的深夜账单",
            criteria: ["D1", "D2", "D4"],
            sourceDomains: ["habit", "finance"]
        )
    }

    private func makeSlots() -> SlotValueTable {
        var table = SlotValueTable()
        table.values["f_1"] = ["weeks": "4", "totalCount": "9"]
        table.values["f_2"] = ["overdueDays": "3"]
        return table
    }

    func testCardBuilderFillsSlotsAndDropsMissingLines() throws {
        let card = try DiscoveryInsightCardBuilder.build(
            selected: makeDraftSelected(),
            slots: makeSlots(),
            portraitIds: ["f_2"]
        )
        XCTAssertEqual(card.version, 4)
        XCTAssertTrue(card.isV4)
        XCTAssertEqual(card.evidenceLines?.count, 2)   // f_missing 行被删
        XCTAssertFalse(card.evidenceLines?.joined().contains("{") ?? true)
        XCTAssertEqual(card.angleKey, "sleep×lateNight")
        XCTAssertEqual(card.topicKey, "sleep×lateNight")
        XCTAssertEqual(card.portraitRefs, ["f_2"])
        XCTAssertEqual(card.sourceDomains, ["habit", "finance"])
    }

    func testCardBuilderThrowsWhenNoEvidenceLeft() {
        var table = SlotValueTable()   // 全空 → 所有行缺值 → 整卡作废
        table.values["f_x"] = [:]
        XCTAssertThrowsError(try DiscoveryInsightCardBuilder.build(
            selected: makeDraftSelected(), slots: table, portraitIds: []
        )) { error in
            XCTAssertEqual(error as? DiscoveryInsightCardBuilder.BuildError, .noEvidenceLeft)
        }
    }

    func testCardBuilderRejectsForeignNumberInEvidence() {
        // 模板自带裸数字（后端闸门漏防的形态）：回填后 4 不来自任何槽位值 → 拒卡。
        var selected = makeDraftSelected()
        selected = InsightDraft.Selected(
            angleKey: selected.angleKey, headline: selected.headline, insight: selected.insight,
            evidence: [
                // 只留裸数字行：f_2 槽位值是 3，模板里的 4 不来自任何槽位 → 拒。
                .init(refId: "f_2", template: "断签那几天任务逾期共4天"),
            ],
            prompt: selected.prompt, criteria: selected.criteria,
            sourceDomains: selected.sourceDomains
        )
        XCTAssertThrowsError(try DiscoveryInsightCardBuilder.build(
            selected: selected, slots: makeSlots(), portraitIds: []
        )) { error in
            XCTAssertEqual(error as? DiscoveryInsightCardBuilder.BuildError, .foreignNumber)
        }
    }

    // MARK: - TopicStore v4

    private func makeStore() -> DiscoveryTopicStore {
        let suite = "discovery-insight-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return DiscoveryTopicStore(defaults: defaults)
    }

    func testTopicStoreV4CardPriorityAndLegacyDecode() throws {
        let store = makeStore()
        let now = Date()
        let v3Card = DiscoveryTopicStore.QueuedCard(
            observationId: "obs-1", topicKey: "k-1", title: "v3标题", body: "v3正文",
            isModelCopy: false, selectedAt: now, windowEnd: now.addingTimeInterval(86_400)
        )
        var v4Card = try DiscoveryInsightCardBuilder.build(
            selected: makeDraftSelected(), slots: makeSlots(), portraitIds: [], now: now
        )
        v4Card.topicKey = "k-4"
        // v3 先入队、v4 后入队：todayCard 必须先出 v4。
        store.enqueue(v3Card)
        store.enqueue(v4Card)
        XCTAssertTrue(store.todayCard(now: now)?.isV4 ?? false)

        // 旧 v3 卡（无新字段编码）解码后 isV4=false、字段为 nil。
        let encoder = JSONEncoder()
        let legacyData = try encoder.encode(v3Card)
        let decoded = try JSONDecoder().decode(DiscoveryTopicStore.QueuedCard.self, from: legacyData)
        XCTAssertFalse(decoded.isV4)
        XCTAssertNil(decoded.insight)
        XCTAssertNil(decoded.angleKey)
    }

    func testTopicStoreDiscardLegacyQueueOnce() {
        let store = makeStore()
        let now = Date()
        store.enqueue(DiscoveryTopicStore.QueuedCard(
            observationId: "obs-legacy", topicKey: "k-legacy", title: "t", body: "b",
            isModelCopy: false, selectedAt: now, windowEnd: now.addingTimeInterval(6 * 7 * 86_400)
        ))
        XCTAssertFalse(store.queue.isEmpty)
        store.discardLegacyQueueIfNeeded()
        XCTAssertTrue(store.queue.isEmpty, "首启应清空库存")
        // 幂等：清空后新入队的卡不被二次清掉
        store.enqueue(DiscoveryTopicStore.QueuedCard(
            observationId: "obs-new", topicKey: "k-new", title: "t", body: "b",
            isModelCopy: true, selectedAt: now, windowEnd: now.addingTimeInterval(86_400)
        ))
        store.discardLegacyQueueIfNeeded()
        XCTAssertEqual(store.queue.count, 1)
    }

    func testTopicStoreQuotaWallMarker() {
        let store = makeStore()
        let now = Date()
        XCTAssertFalse(store.isInsightQuotaWalledToday(now: now))
        store.markInsightQuotaWalled(now: now)
        XCTAssertTrue(store.isInsightQuotaWalledToday(now: now))
        // 次日重新探（服务端权威，客户端只做当日展示标记）
        XCTAssertFalse(store.isInsightQuotaWalledToday(now: now.addingTimeInterval(2 * 86_400)))
    }

    func testTopicStoreAngleMemoryAndDayMarkers() {
        let store = makeStore()
        let now = Date()
        XCTAssertFalse(store.insightV2AttemptedToday(now: now))
        store.markInsightV2Attempted(now: now)
        XCTAssertTrue(store.insightV2AttemptedToday(now: now))
        XCTAssertFalse(store.insightV2AttemptedToday(now: now.addingTimeInterval(2 * 86_400)))

        XCTAssertFalse(store.insightV2NoneWorthwhileToday(now: now))
        store.markInsightV2NoneWorthwhile(now: now)
        XCTAssertTrue(store.insightV2NoneWorthwhileToday(now: now))

        store.markInsightAngleShown("a×b", now: now)
        store.markInsightAngleShown("c×d", now: now.addingTimeInterval(-40 * 86_400)) // 超 30 天
        XCTAssertEqual(store.recentAngleKeys(now: now), ["a×b"])

        store.markInsightAngleRejected("a×b", now: now)
        XCTAssertEqual(store.rejectedAngleKeys, ["a×b"])
    }

    // MARK: - FeedbackBridge（画像仓注入临时目录）

    @MainActor
    func testFeedbackConfirmCreatesPortraitEntryWithoutRefs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insight-fb-\(UUID().uuidString)")
        let store = makeStore()
        let now = Date()
        var card = try DiscoveryInsightCardBuilder.build(
            selected: makeDraftSelected(), slots: makeSlots(), portraitIds: [], now: now
        )
        card.topicKey = "angle-confirm"
        card.angleKey = "angle-confirm"
        store.enqueue(card)

        let outcome = DiscoveryInsightFeedbackBridge.confirm(card: card, now: now, directory: dir, topicStore: store)
        guard case .createdPortrait = outcome else {
            return XCTFail("应新建画像条目: \(outcome)")
        }
        var portrait = PortraitStore.load(directory: dir)
        let entry = try XCTUnwrap(portrait.entries.values.first { $0.dimension == .crossDomainInsight })
        XCTAssertEqual(entry.confidence, .confirmed)
        XCTAssertTrue(entry.isUserConfirmed)
        // evidenceSummary 不含数字（回填行里的数字被剥离）。
        XCTAssertFalse(InsightNumberDiscipline.containsNumerals(in: entry.evidenceSummary))
    }

    @MainActor
    func testFeedbackRejectBlacklistsPortraitAndAngle() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insight-fb-\(UUID().uuidString)")
        let store = makeStore()
        let now = Date()
        var card = try DiscoveryInsightCardBuilder.build(
            selected: makeDraftSelected(), slots: makeSlots(), portraitIds: [], now: now
        )
        card.topicKey = "angle-reject"
        card.angleKey = "angle-reject"
        card.portraitRefs = ["p_early_sleep"]
        store.enqueue(card)
        var next = card
        next.topicKey = "next-card"
        next.angleKey = "next-card"
        store.enqueue(next)

        XCTAssertEqual(
            DiscoveryInsightFeedbackBridge.reject(card: card, now: now, directory: dir, topicStore: store),
            .rejected(angleKey: "angle-reject", portraitKeys: ["p_early_sleep"])
        )
        // 画像进黑名单永不复活。
        var portrait = PortraitStore.load(directory: dir)
        XCTAssertNil(portrait.entries["p_early_sleep"])
        XCTAssertTrue(portrait.rejectedBlacklist.contains { $0.key == "p_early_sleep" })
        // 角度进拒绝列表（下次 packet.rejectedAngles 带上）。
        XCTAssertTrue(store.rejectedAngleKeys.contains("angle-reject"))
        // 今日卡已消费。
        XCTAssertNil(store.todayCard(now: now))
        XCTAssertTrue(store.consumedToday(now: now))
        XCTAssertEqual(store.queue, [next])
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: now))
        XCTAssertEqual(store.todayCard(now: tomorrow), next)
        XCTAssertEqual(
            DiscoveryInsightFeedbackBridge.reject(card: card, now: tomorrow, directory: dir, topicStore: store),
            .unavailable
        )
        XCTAssertEqual(store.todayCard(now: tomorrow), next)
    }

    @MainActor
    func testFeedbackRejectKeepsCardIfPortraitSaveFails() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("insight-fb-file-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = makeStore()
        let now = Date()
        var card = try DiscoveryInsightCardBuilder.build(
            selected: makeDraftSelected(), slots: makeSlots(), now: now
        )
        card.portraitRefs = ["p_early_sleep"]
        store.enqueue(card)

        XCTAssertEqual(
            DiscoveryInsightFeedbackBridge.reject(card: card, now: now, directory: file, topicStore: store),
            .persistenceFailed
        )
        XCTAssertEqual(store.todayCard(now: now), card)
        XCTAssertFalse(store.consumedToday(now: now))
        XCTAssertTrue(store.rejectedAngleKeys.isEmpty)
    }

    @MainActor
    func testFeedbackDeferUsesSevenDayCooldown() throws {
        let store = makeStore()
        let now = Date()
        var card = try DiscoveryInsightCardBuilder.build(
            selected: makeDraftSelected(), slots: makeSlots(), portraitIds: [], now: now
        )
        card.topicKey = "angle-defer"
        card.angleKey = "angle-defer"
        store.enqueue(card)

        _ = DiscoveryInsightFeedbackBridge.deferCard(card: card, now: now, topicStore: store)
        // 冷却中的角度在 deferredActiveKeys 里（7 天口径沿用 v3）。
        XCTAssertTrue(store.deferredActiveKeys(now: now).contains("angle-defer"))
        XCTAssertNil(store.todayCard(now: now))
    }

    // MARK: - 2026-11-21 Plus 分层 I2：本机短句

    func testTeaserPhrasesFollowCopyTable() throws {
        let output = try XCTUnwrap(DiscoveryInsightCandidateBuilder.build(
            portraitStore: makePortraitStore(), featurePacket: makeFeaturePacket(),
            proposals: [makeMinerProposal()], recentTopics: [], rejectedAngles: []
        ))
        let p = output.teaserPhrases
        XCTAssertEqual(p["f_anomaly_0"], "最近你睡得越来越晚")
        XCTAssertEqual(p["f_anomaly_1"], "「咖啡」最近记的数值在变多")
        XCTAssertEqual(p["f_checkin_0"], "「冥想」最近打卡比之前少了")
        XCTAssertEqual(p["f_concept_0"], "你经常买「猫粮」，多在深夜")
        XCTAssertEqual(p["f_sleep_duration"], "最近你睡得比之前短了")
        XCTAssertEqual(p["f_steps_change"], "最近你每天走的路比之前少了")
        // 挖掘器提案不生成短句
        XCTAssertTrue(p.keys.allSatisfy { !$0.hasPrefix("f_miner_") })
        // 短句不含数字、不进上传包
        XCTAssertTrue(p.values.allSatisfy { !InsightNumberDiscipline.containsNumerals(in: $0) })
        XCTAssertFalse(output.packet.encodeJSON()?.contains("最近你睡得越来越晚") ?? true)
    }

    // MARK: - 2026-11-21 Plus 分层 I3：预告问题

    private func feature(_ id: String, _ domain: String) -> InsightInputPacket.FeatureItem {
        InsightInputPacket.FeatureItem(id: id, domain: domain, description: "d", direction: "up", slots: [])
    }

    private func teaserPacket(_ features: [InsightInputPacket.FeatureItem]) -> InsightInputPacket {
        InsightInputPacket(schemaVersion: 1, kind: "insightInput", requestId: "r", window: .init(days: 28),
                           portrait: [], features: features, userIntents: [], recentTopics: [], rejectedAngles: [])
    }

    func testTeaserPairsAcrossDomainsAndDropsSecondRecent() {
        let packet = teaserPacket([feature("a", "health"), feature("b", "habit")])
        let clues = DiscoveryTeaserBuilder.build(packet: packet, phrases: [
            "a": "最近你睡得越来越晚", "b": "「冥想」最近打卡比之前少了",
        ])
        XCTAssertEqual(clues.count, 1)
        XCTAssertEqual(clues[0].text, "最近你睡得越来越晚，同一段时间「冥想」打卡比之前少了。这两件事有关系吗？")
        XCTAssertEqual(clues[0].phrases, ["最近你睡得越来越晚", "「冥想」最近打卡比之前少了"])
    }

    func testTeaserSameDomainStaysSingleAndRespectsLimitAndExclusion() {
        let packet = teaserPacket([
            feature("a", "health"), feature("b", "health"), feature("c", "health"),
            feature("d", "health"), feature("e", "health"),
        ])
        let phrases = ["a": "最近你睡得比较少", "b": "最近你睡得越来越晚", "c": "最近你走路、运动少了",
                       "d": "最近你睡得比之前短了", "e": "最近你每天走的路比之前少了"]
        let clues = DiscoveryTeaserBuilder.build(packet: packet, phrases: phrases, excludingFeatureIds: ["a"])
        XCTAssertEqual(clues.count, 3)
        XCTAssertEqual(clues[0].text, "最近你睡得越来越晚，Holo 想帮你看看是为什么。")
    }

    func testTeaserSkipsFeaturesWithoutPhrase() {
        let packet = teaserPacket([feature("f_miner_0", "finance"), feature("a", "health")])
        let clues = DiscoveryTeaserBuilder.build(packet: packet, phrases: ["a": "最近你睡得比较少"])
        XCTAssertEqual(clues.map(\.text), ["最近你睡得比较少，Holo 想帮你看看是为什么。"])
    }

    func testTeaserFromRealBuilderOutput() throws {
        let output = try XCTUnwrap(DiscoveryInsightCandidateBuilder.build(
            portraitStore: makePortraitStore(), featurePacket: makeFeaturePacket(),
            proposals: [], recentTopics: [], rejectedAngles: []
        ))
        let clues = DiscoveryTeaserBuilder.build(packet: output.packet, phrases: output.teaserPhrases)
        XCTAssertFalse(clues.isEmpty)
        XCTAssertLessThanOrEqual(clues.count, 3)
        // 数字纪律作用于短句（可变部分）：固定句式「两件事」是文案真源原文，不在检查范围。
        XCTAssertTrue(clues.allSatisfy { clue in
            !clue.phrases.contains(where: { InsightNumberDiscipline.containsNumerals(in: $0) })
        })
    }
}
