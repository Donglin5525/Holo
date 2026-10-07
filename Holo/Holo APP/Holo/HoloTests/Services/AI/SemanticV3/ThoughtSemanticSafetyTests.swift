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
