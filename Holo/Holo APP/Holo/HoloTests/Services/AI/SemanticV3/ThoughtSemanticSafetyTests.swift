//
//  ThoughtSemanticSafetyTests.swift
//  HoloTests
//
//  2026-09-24 方案 A 阶段 P0 修复的协议/状态不变量测试：
//  ① verifier quote 区间先验边界（恶意/异常模型返回不崩、不误判逐字）
//  ② V2 自动整理停算矩阵默认值（显式设置优先；未设置时新 UI 构建=停）
//  ③ 语义库覆盖统计与失败重试（pending=0 ≠ 完成；finished_at 幂等加列）
//

import XCTest
import CoreData
@testable import Holo

final class ThoughtSemanticSafetyTests: XCTestCase {

    // MARK: - ① quote 区间安全

    func testQuoteVerbatimAcceptsExactRange() {
        let text = "今天开始每天记录一点想法，看看一个月后有什么变化。"
        // 今(0)天(1)开(2)始(3)每(4)天(5)记(6)录(7)：「每天记录」= [4, 8)
        XCTAssertTrue(ThoughtTopicVerifier.isQuoteVerbatim("每天记录", in: text, rangeUTF16: [4, 8]))
    }

    func testQuoteVerbatimRejectsOutOfBounds() {
        let text = "短文本"
        // 越界：end 超过 UTF-16 长度
        XCTAssertFalse(ThoughtTopicVerifier.isQuoteVerbatim("文本", in: text, rangeUTF16: [0, 100]))
        // 负数
        XCTAssertFalse(ThoughtTopicVerifier.isQuoteVerbatim("文", in: text, rangeUTF16: [-1, 1]))
        // 倒序
        XCTAssertFalse(ThoughtTopicVerifier.isQuoteVerbatim("", in: text, rangeUTF16: [2, 1]))
        // nil / 非 2 元素
        XCTAssertFalse(ThoughtTopicVerifier.isQuoteVerbatim("文", in: text, rangeUTF16: nil))
        XCTAssertFalse(ThoughtTopicVerifier.isQuoteVerbatim("文", in: text, rangeUTF16: [0]))
        XCTAssertFalse(ThoughtTopicVerifier.isQuoteVerbatim("文", in: text, rangeUTF16: [0, 1, 2]))
    }

    func testQuoteVerbatimHandlesEmojiSurrogatePairs() {
        // emoji 占 2 个 UTF-16 单元：区间切在代理对中间时切片≠quote，必须判 false 而非崩溃
        let text = "💡今天有灵感"
        XCTAssertTrue(ThoughtTopicVerifier.isQuoteVerbatim("💡", in: text, rangeUTF16: [0, 2]))
        XCTAssertFalse(ThoughtTopicVerifier.isQuoteVerbatim("💡", in: text, rangeUTF16: [1, 3]))
        XCTAssertFalse(ThoughtTopicVerifier.isQuoteVerbatim("今天", in: text, rangeUTF16: [2, 10]))
    }

    func testQuoteVerbatimRejectsNonMatchingSubstring() {
        let text = "这句话里没有目标词"
        XCTAssertFalse(ThoughtTopicVerifier.isQuoteVerbatim("不存在", in: text, rangeUTF16: [0, 3]))
    }

    // MARK: - ② V2 停算矩阵默认值

    func testAutoOrganizationDefaultFollowsUIFlag() {
        let suite = "test-auto-org-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // V3 收口（2026-10-03）：自动主题统一走 V3 Pipeline 的 automatic 开关，
        // V2 策略退役恒停——UI 形态、显式设置都不再翻开旧策略（显式回滚通道
        // 由 ThoughtSemanticFeatureFlags.automatic 承担，另有测试覆盖）。
        defaults.set(true, forKey: "thought_semantic_v3_ui")
        XCTAssertFalse(ThoughtAIClassificationPolicy.isEnabled(in: defaults))

        defaults.removeObject(forKey: "thought_semantic_v3_ui")
        defaults.set(false, forKey: "thought_semantic_v3_ui")
        XCTAssertFalse(ThoughtAIClassificationPolicy.isEnabled(in: defaults))

        defaults.set(true, forKey: ThoughtAIClassificationPolicy.isEnabledKey)
        XCTAssertFalse(ThoughtAIClassificationPolicy.isEnabled(in: defaults))
        defaults.set(false, forKey: ThoughtAIClassificationPolicy.isEnabledKey)
        XCTAssertFalse(ThoughtAIClassificationPolicy.isEnabled(in: defaults))
    }

    // MARK: - ③ 覆盖统计与失败重试

    private func makeStore() async throws -> (ThoughtSemanticStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("semantic-safety-test-\(UUID().uuidString)")
        let store = await ThoughtSemanticStore(root: root)
        try await store.open()
        return (store, root)
    }

    // MARK: - ④ 主题双通道候选召回（2026-10-12）

    @discardableResult
    private func insertSemanticTopic(_ ctx: NSManagedObjectContext, title: String, classification: Bool) throws -> Topic {
        let topic = ctx.insertTestObject(Topic.self)
        topic.id = UUID()
        topic.title = title
        topic.status = classification ? Topic.TopicStatus.classification.rawValue : Topic.TopicStatus.active.rawValue
        topic.titleSource = "user"
        topic.confidence = 0
        topic.thoughtCount = 0
        topic.createdAt = Date()
        topic.updatedAt = Date()
        topic.topicRevision = 1
        try ctx.save()
        return topic
    }

    /// 类别通道全量直达：classification 主题不经相似度竞争直接进候选（kind=category），
    /// 脉络主题仍走原通道（无向量大目录 ≤3 走小目录兜底）；全程零网络调用。
    func testRecallCategoryChannelFullAccessWithoutCompetition() async throws {
        let ctx = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(ctx, ["Topic"])
        try insertSemanticTopic(ctx, title: "碎碎念", classification: true)
        try insertSemanticTopic(ctx, title: "工作与事业", classification: true)
        let threadA = try insertSemanticTopic(ctx, title: "跑步训练", classification: false)
        let threadB = try insertSemanticTopic(ctx, title: "产品思考", classification: false)

        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = HoloBackendAIProvider(baseURL: "https://mock.local",
            apiClient: APIClient(urlSession: URLSession(configuration: .ephemeral)))
        let vector = SemanticVectorMath.normalized((0..<1024).map { _ in Float.random(in: -1...1) })

        let outcome = try await ThoughtTopicCandidateEngine.recall(
            targetVector: vector, thoughtID: UUID(), store: store, index: nil,
            context: ctx, calibration: .seed, provider: provider)

        let categories = outcome.candidates.filter { $0.kind == "category" }
        let threads = outcome.candidates.filter { $0.kind == "thread" }
        XCTAssertEqual(Set(categories.map(\.topicTitle)), Set(["碎碎念", "工作与事业"]),
                       "用户类别必须全量直达，不与脉络争名额")
        XCTAssertEqual(Set(threads.map(\.topicID)), Set([threadA.id, threadB.id]),
                       "脉络主题走原通道（小目录兜底）")
        XCTAssertNil(outcome.reason)
    }

    /// 类别通道全量核对（A1 自查修复）：不再按标题码点砍主题；成员多的证据足优先。
    func testRecallCategoryChannelFullCoverageAndEvidenceOrdering() async throws {
        let ctx = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(ctx, ["Topic", "Thought", "ThoughtTopicLink"])
        // 大主题：2 条有效成员；小主题：1 条；三个空主题——全部都应进候选，大者在前
        func makeMember(_ name: String) throws -> Thought {
            let t = ctx.insertTestObject(Thought.self)
            t.id = UUID()
            t.content = name
            t.createdAt = Date()
            t.updatedAt = Date()
            t.orderIndex = 0
            t.organizedStatus = "organized"
            return t
        }
        func link(_ thought: Thought, _ topic: Topic) {
            let l = ctx.insertTestObject(ThoughtTopicLink.self)
            l.id = ThoughtTopicLink.deterministicID(thoughtID: thought.id, topicID: topic.id)
            l.thought = thought
            l.topic = topic
            l.sourceEnum = .userManual
            l.stateEnum = .active
            l.visibilityEnum = .internalOnly
            l.consentGeneration = 0
            l.createdAt = Date()
            l.updatedAt = Date()
        }
        let richTopic = try insertSemanticTopic(ctx, title: "类别小样本", classification: true)
        let thinTopic = try insertSemanticTopic(ctx, title: "类别大样本", classification: true)
        let m1 = try makeMember("成员一")
        let m2 = try makeMember("成员二")
        let m3 = try makeMember("成员三")
        link(m1, richTopic); link(m2, richTopic); link(m3, thinTopic)
        for index in 0..<3 {
            try insertSemanticTopic(ctx, title: "空类别\(index)", classification: true)
        }
        try ctx.save()

        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = HoloBackendAIProvider(baseURL: "https://mock.local",
            apiClient: APIClient(urlSession: URLSession(configuration: .ephemeral)))
        let vector = SemanticVectorMath.normalized((0..<1024).map { _ in Float.random(in: -1...1) })

        let outcome = try await ThoughtTopicCandidateEngine.recall(
            targetVector: vector, thoughtID: UUID(), store: store, index: nil,
            context: ctx, calibration: .seed, provider: provider)

        let categories = outcome.candidates.filter { $0.kind == "category" }
        XCTAssertEqual(categories.count, 5, "5 个分类主题全量进候选，不再有任意截断")
        // richTopic 2 条成员但标题按码点排在 thinTopic（1 条成员）之后：
        // 断言 rich 在前 = 排序依据是成员数而非标题，A1 修复的核心行为。
        XCTAssertEqual(categories.first?.topicID, richTopic.id)
    }

    /// 用户拒绝墓碑同样压制类别候选：手动移出过的主题，类别通道也不得再收。
    func testRecallRejectedTombstoneSuppressesCategoryCandidate() async throws {
        let ctx = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(ctx, ["Topic", "Thought", "ThoughtTopicLink"])
        let thought = ctx.insertTestObject(Thought.self)
        thought.id = UUID()
        thought.content = "测试想法"
        thought.createdAt = Date()
        thought.updatedAt = Date()
        thought.orderIndex = 0
        thought.organizedStatus = "organized"
        let topic = try insertSemanticTopic(ctx, title: "碎碎念", classification: true)
        let link = ctx.insertTestObject(ThoughtTopicLink.self)
        link.id = ThoughtTopicLink.deterministicID(thoughtID: thought.id, topicID: topic.id)
        link.thought = thought
        link.topic = topic
        link.sourceEnum = .userManual
        link.stateEnum = .rejected
        link.visibilityEnum = .internalOnly
        link.consentGeneration = 0
        link.createdAt = Date()
        link.updatedAt = Date()
        try ctx.save()

        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = HoloBackendAIProvider(baseURL: "https://mock.local",
            apiClient: APIClient(urlSession: URLSession(configuration: .ephemeral)))
        let vector = SemanticVectorMath.normalized((0..<1024).map { _ in Float.random(in: -1...1) })

        let outcome = try await ThoughtTopicCandidateEngine.recall(
            targetVector: vector, thoughtID: thought.id, store: store, index: nil,
            context: ctx, calibration: .seed, provider: provider)

        XCTAssertTrue(outcome.candidates.isEmpty, "唯一类别被墓碑压制后不得有任何候选")
        XCTAssertEqual(outcome.reason, "below_recall_threshold")
    }

    // MARK: - ⑤ 类别理解 brief（2026-10-12 主题双通道·零打扰）

    /// 铁律：排除项只增不减；无新移出时 AI 提议的新排除全部丢弃。
    func testBriefExclusionsMergeIronRule() {
        let previous = ["纯转载", "任务清单"]
        // 无新移出：AI 想加「会议纪要」→ 丢弃（边界只由用户动作改写）
        XCTAssertEqual(ThoughtCategoryBriefClient.mergedExclusions(
            previous: previous, proposed: ["纯转载", "会议纪要"], newRemovalCount: 0), previous)
        // 有新移出：允许追加，永不删除已有项
        XCTAssertEqual(ThoughtCategoryBriefClient.mergedExclusions(
            previous: previous, proposed: ["纯转载", "行业报告转载"], newRemovalCount: 1),
            ["纯转载", "任务清单", "行业报告转载"])
        // 上限 6：追加截断不溢出
        let six = ["一", "二", "三", "四", "五", "六"]
        XCTAssertEqual(ThoughtCategoryBriefClient.mergedExclusions(
            previous: six, proposed: ["七"], newRemovalCount: 2).count, 6)
    }

    /// brief 库表往返：保存/读回/版本键排序（版本键进关联重评指纹，稳定性必须锁定）。
    func testCategoryBriefStoreRoundTripAndVersionKeys() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let topicID = UUID()
        let initial = try await store.loadCategoryBrief(topicID: topicID)
        XCTAssertNil(initial)

        let record = ThoughtSemanticStore.CategoryBriefRecord(
            topicID: topicID, version: 1,
            definition: "个人生活片段、即时感受、吐槽，以及个人观察与反思。",
            exclusions: ["纯转载", "任务清单"],
            basisMemberCount: 12, basisRemovalCount: 1, updatedAt: Date())
        try await store.saveCategoryBrief(record)

        let loaded = try await store.loadCategoryBrief(topicID: topicID)
        XCTAssertEqual(loaded?.definition, record.definition)
        XCTAssertEqual(loaded?.exclusions, record.exclusions)
        XCTAssertEqual(loaded?.basisMemberCount, 12)
        XCTAssertEqual(loaded?.basisRemovalCount, 1)

        let other = ThoughtSemanticStore.CategoryBriefRecord(
            topicID: UUID(), version: 3, definition: "工作与事业的观察记录。",
            exclusions: [], basisMemberCount: 8, basisRemovalCount: 0, updatedAt: Date())
        try await store.saveCategoryBrief(other)
        let keys = try await store.allCategoryBriefVersionKeys()
        XCTAssertEqual(keys.count, 2)
        XCTAssertTrue(keys.contains("\(topicID.uuidString):1"))
        XCTAssertTrue(keys.contains("\(other.topicID.uuidString):3"))
    }

    /// 响应二次校验：证据逐字回源才放行；伪 quote / 越界定义 / 空 evidence 拒绝。
    func testBriefValidatedContentContract() {
        let request = ThoughtCategoryBriefClient.makeRequest(
            title: "碎碎念", userDefinition: nil, currentBrief: nil,
            members: [
                ("R0", "食堂两个肉菜 53 块，这定价是认真的吗。", "user"),
                ("R1", "出门喂猫的时候发现楼下的桂花开了。", "user"),
                ("R2", "Agent 越来越能干，人反而更不敢拍板了。", "ai"),
            ],
            removals: [])!
        func response(_ brief: ThoughtCategoryBriefResponseDTO.Brief,
                      evidence: [ThoughtCategoryBriefResponseDTO.Evidence]) -> ThoughtCategoryBriefResponseDTO {
            .init(schemaVersion: 1, operationId: request.operationId, brief: brief, evidence: evidence)
        }
        let good = ThoughtCategoryBriefClient.validatedContent(from: response(
            .init(definition: "个人生活片段、即时感受、吐槽与观察反思。", exclusions: ["纯转载", ""]),
            evidence: [.init(ref: "R0", quote: "这定价是认真的吗")]), request: request)
        XCTAssertEqual(good?.exclusions, ["纯转载"], "排除项去空")

        XCTAssertNil(ThoughtCategoryBriefClient.validatedContent(from: response(
            .init(definition: "定义", exclusions: []),
            evidence: [.init(ref: "R0", quote: "不在原文里的字")]), request: request))
        XCTAssertNil(ThoughtCategoryBriefClient.validatedContent(from: response(
            .init(definition: "定".padding(toLength: 250, withPad: "义", startingAt: 0), exclusions: []),
            evidence: [.init(ref: "R0", quote: "这定价是认真的吗")]), request: request), "定义超 240 拒绝")
        XCTAssertNil(ThoughtCategoryBriefClient.validatedContent(from: response(
            .init(definition: "定义", exclusions: []), evidence: []), request: request), "空 evidence 拒绝")
    }

    func testIndexStatsDistinguishesPendingFailedAndUnavailable() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // 3 条任务：1 完成(正常) 1 完成(纯图跳过) 1 失败终态
        let jobs = [
            ThoughtSemanticStore.SemanticJob(id: UUID(), thoughtID: UUID(), contentHash: "h1",
                                             kind: "embed", priority: 0, state: "pending", attemptCount: 0,
                                             nextAttemptAt: nil, consentGeneration: 0, lastErrorCode: nil),
            ThoughtSemanticStore.SemanticJob(id: UUID(), thoughtID: UUID(), contentHash: "h2",
                                             kind: "embed", priority: 0, state: "pending", attemptCount: 0,
                                             nextAttemptAt: nil, consentGeneration: 0, lastErrorCode: nil),
            ThoughtSemanticStore.SemanticJob(id: UUID(), thoughtID: UUID(), contentHash: "h3",
                                             kind: "embed", priority: 0, state: "pending", attemptCount: 0,
                                             nextAttemptAt: nil, consentGeneration: 0, lastErrorCode: nil)
        ]
        for job in jobs { try await store.enqueueJob(job) }
        try await store.finishJob(id: jobs[0].id, state: "done")
        try await store.finishJob(id: jobs[1].id, state: "done", errorCode: "text_unavailable")
        try await store.finishJob(id: jobs[2].id, state: "failed_terminal", errorCode: "network_or_upstream")

        let stats = try await store.indexStats()
        XCTAssertEqual(stats.pendingJobs, 0)
        XCTAssertEqual(stats.failedJobs, 1)
        XCTAssertEqual(stats.unavailableDone, 1)
        XCTAssertNotNil(stats.lastFinishedAt, "终态任务须记录 finished_at（幂等加列）")
    }

    func testRetryFailedResetsOnlyFailedJobs() async throws {
        let (store, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let failed = ThoughtSemanticStore.SemanticJob(id: UUID(), thoughtID: UUID(), contentHash: "hf",
                                                      kind: "embed", priority: 0, state: "pending", attemptCount: 0,
                                                      nextAttemptAt: nil, consentGeneration: 0, lastErrorCode: nil)
        let done = ThoughtSemanticStore.SemanticJob(id: UUID(), thoughtID: UUID(), contentHash: "hd",
                                                    kind: "embed", priority: 0, state: "pending", attemptCount: 0,
                                                    nextAttemptAt: nil, consentGeneration: 0, lastErrorCode: nil)
        try await store.enqueueJob(failed)
        try await store.enqueueJob(done)
        try await store.finishJob(id: failed.id, state: "failed_terminal", errorCode: "network_or_upstream")
        try await store.finishJob(id: done.id, state: "done")

        try await store.retryFailedJobs()

        let stats = try await store.indexStats()
        XCTAssertEqual(stats.pendingJobs, 1, "仅失败任务回到待处理")
        XCTAssertEqual(stats.failedJobs, 0)
        XCTAssertEqual(stats.unavailableDone, 0, "正常完成任务不受重试影响")
    }

    // MARK: - ④ relation=on 正式写入不变量（B 阶段）

    @MainActor
    private func makeLinkPair() throws -> (Thought, Topic) {
        let context = CoreDataTestSupport.sharedTestContainer.viewContext
        let thought = Thought(context: context)
        thought.id = UUID()
        thought.content = "样本想法 \(UUID().uuidString.prefix(6))"
        thought.createdAt = Date()
        thought.updatedAt = Date()
        let topic = Topic(context: context)
        topic.id = UUID()
        topic.title = "主题 \(UUID().uuidString.prefix(4))"
        topic.status = Topic.TopicStatus.classification.rawValue
        topic.createdAt = Date()
        topic.updatedAt = Date()
        return (thought, topic)
    }

    @MainActor
    func testAIV3DecisionDoesNotReviveRejectedTombstone() throws {
        try CoreDataTestSupport.clearEntities(CoreDataTestSupport.sharedTestContainer.viewContext,
                                              ["ThoughtTopicLink", "Thought", "Topic"])
        let (thought, topic) = try makeLinkPair()
        // 用户拒绝墓碑
        ThoughtTopicLinkProjection.recordManualRemove(thought: thought, topic: topic)
        try thought.managedObjectContext?.save()

        let wrote = ThoughtTopicLinkProjection.recordAIV3Decision(
            thought: thought, topic: topic, basisTextHash: "hash-1",
            decisionTier: "high", engineVersion: "thought_semantic_v3.0",
            consentGeneration: 1)
        XCTAssertFalse(wrote, "拒绝墓碑必须压制 AI 写入")

        let request = ThoughtTopicLink.fetchRequest()
        request.predicate = NSPredicate(format: "thought == %@ AND topic == %@", thought, topic)
        let rows = try XCTUnwrap(thought.managedObjectContext?.fetch(request))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.stateEnum, .rejected, "墓碑不复活")
    }

    @MainActor
    func testAIV3DecisionDoesNotDowngradeUserActiveLink() throws {
        try CoreDataTestSupport.clearEntities(CoreDataTestSupport.sharedTestContainer.viewContext,
                                              ["ThoughtTopicLink", "Thought", "Topic"])
        let (thought, topic) = try makeLinkPair()
        ThoughtTopicLinkProjection.recordManualAdd(thought: thought, topic: topic)
        try thought.managedObjectContext?.save()

        let wrote = ThoughtTopicLinkProjection.recordAIV3Decision(
            thought: thought, topic: topic, basisTextHash: "hash-1",
            decisionTier: "high", engineVersion: "thought_semantic_v3.0",
            consentGeneration: 1)
        XCTAssertFalse(wrote, "用户 active 行不降级")

        let request = ThoughtTopicLink.fetchRequest()
        request.predicate = NSPredicate(format: "thought == %@ AND topic == %@", thought, topic)
        let rows = try XCTUnwrap(thought.managedObjectContext?.fetch(request))
        XCTAssertEqual(rows.first?.sourceEnum, .userManual, "用户手动关系保留")
        XCTAssertEqual(rows.first?.visibilityEnum, .userVisible)
    }

    @MainActor
    func testAIV3DecisionWritesFields() throws {
        try CoreDataTestSupport.clearEntities(CoreDataTestSupport.sharedTestContainer.viewContext,
                                              ["ThoughtTopicLink", "Thought", "Topic"])
        let (thought, topic) = try makeLinkPair()

        let wrote = ThoughtTopicLinkProjection.recordAIV3Decision(
            thought: thought, topic: topic, basisTextHash: "hash-9",
            decisionTier: "high", engineVersion: "thought_semantic_v3.0",
            consentGeneration: 2, evidenceRange: [10, 24])
        XCTAssertTrue(wrote)
        try thought.managedObjectContext?.save()

        let request = ThoughtTopicLink.fetchRequest()
        request.predicate = NSPredicate(format: "thought == %@ AND topic == %@", thought, topic)
        let rows = try XCTUnwrap(thought.managedObjectContext?.fetch(request))
        let link = try XCTUnwrap(rows.first)
        XCTAssertEqual(link.sourceEnum, .aiV3)
        XCTAssertEqual(link.stateEnum, .active)
        XCTAssertEqual(link.visibilityEnum, .weakVisible)
        XCTAssertEqual(link.basisTextHash, "hash-9")
        XCTAssertEqual(link.decisionTier, "high")
        XCTAssertEqual(link.consentGeneration, 2)
        XCTAssertEqual(link.evidenceRange, "10,24")
    }

    // MARK: - ⑤ 侧栏全路径口径与标签树（A1 阶段）

    func testFullPathMatchingDoesNotMergeSameLeafSegment() {
        // 叶段同名但路径不同：不得合并（方案 §6.5）
        XCTAssertFalse(ThoughtTagNormalizer.matchesFullPath(tagKey: "工作/想法", scopePathKey: "生活/想法"))
        XCTAssertTrue(ThoughtTagNormalizer.matchesFullPath(tagKey: "工作/想法", scopePathKey: "工作/想法"))
        // 选父含全部子路径
        XCTAssertTrue(ThoughtTagNormalizer.matchesFullPath(tagKey: "工作/想法/设计", scopePathKey: "工作"))
        XCTAssertTrue(ThoughtTagNormalizer.matchesFullPath(tagKey: "工作/想法", scopePathKey: "工作"))
        // 前缀是段前缀不算（工作x ≠ 工作）
        XCTAssertFalse(ThoughtTagNormalizer.matchesFullPath(tagKey: "工作台", scopePathKey: "工作"))
    }

    func testTagTreeBuilderNestsPaths() {
        let tree = ThoughtSidebarTagTreeBuilder.build(from: ["工作/想法", "生活/运动", "工作", "工作/项目/Holo"])
        XCTAssertEqual(tree.count, 2, "两个根：工作、生活")
        let work = tree.first { $0.displayName == "工作" }
        XCTAssertNotNil(work)
        let workChildren = work?.children.map(\.displayName).sorted() ?? []
        XCTAssertEqual(workChildren, ["想法", "项目"], "子层按路径折叠")
        let project = work?.children.first { $0.displayName == "项目" }
        XCTAssertEqual(project?.children.map(\.displayName), ["Holo"], "三层嵌套")
    }
}
