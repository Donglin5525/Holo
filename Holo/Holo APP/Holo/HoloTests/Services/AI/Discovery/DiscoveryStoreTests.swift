//
//  DiscoveryStoreTests.swift
//  HoloTests
//
//  「一个发现」G1 本机 store 测试（内存 store 注入）：
//  原子提交回滚、失效依赖查询、发布唯一约束、tombstone HMAC 稳定性、账号清理保留指纹。
//  待挂载 HoloTests target（本文件为新增，未改动 pbxproj，由主会话统一挂载）。
//

// 待挂载 HoloTests target
import XCTest
import CoreData
import CryptoKit
@testable import Holo

final class DiscoveryStoreTests: XCTestCase {

    /// iOS 26.3 测试宿主坑（habit-drag-session-deadlock-1011 档案）：同步用例默认跑在
    /// MainActor 执行器上下文，其中分配/释放的类（store 的 DiscoverySyncBox）析构踩
    /// swift_task_deinitOnExecutorMainActorBackDeploy 的 TaskLocal double-free。
    /// 产品路径在后台队列调用不受影响；测试整体挪到全局队列执行规避。
    override func invokeTest() {
        DispatchQueue.global(qos: .userInitiated).sync {
            super.invokeTest()
        }
    }

    private var fixedNow: Date { Date(timeIntervalSince1970: 1_790_000_000) }

    private func makeStore(salt: String = "test-salt") throws -> DiscoveryStore {
        try DiscoveryStore(configuration: .init(
            inMemory: true,
            feedbackKey: Data(repeating: 0x07, count: 32),
            feedbackSalt: salt
        ))
    }

    private func makeFreeze(runID: String = "run-1") -> DiscoveryRunFreeze {
        DiscoveryRunFreeze(
            runID: runID,
            accountSubject: "device-subject-1",
            deviceID: "device-1",
            localGrantEpoch: 1,
            serverControlRevision: 3,
            scopeRevision: DiscoveryScopeRevision.digest(domains: [.thought]),
            sourceManifestDigest: "digest-1",
            candidatePromptVersion: 1,
            verifyPromptVersion: 1,
            modelRouteVersion: 1,
            policyVersion: 1,
            anchorNow: fixedNow,
            timezone: "Asia/Shanghai"
        )
    }

    private func makePayload(candidateID: String = "C01") -> DiscoveryPublishedPayload {
        DiscoveryPublishedPayload(
            candidateID: candidateID,
            type: .twoEpisodes,
            title: "这两次重新开始，你都把第一步变轻了。",
            body: ["恢复运动时先走十分钟，重新阅读时先翻两页。"],
            citations: [
                .init(evidenceID: "E01", quote: "今天先出去走了十分钟", sourceRef: "thought:uuid-1"),
                .init(evidenceID: "E02", quote: "今晚只翻了两页", sourceRef: "thought:uuid-2"),
            ],
            coverageNote: "范围：近 30 天想法；未读取归档与排除记录。",
            sensitivity: .nonSensitive,
            timeRange: DiscoveryTimeRange(
                start: "2026-10-08T00:00:00+08:00",
                end: "2026-10-17T00:00:00+08:00"
            ),
            fingerprintMaterial: "subject:lighter-start"
        )
    }

    // MARK: - 原子提交

    func test_原子提交_body抛错整体回滚不留半截() throws {
        let store = try makeStore()
        struct Boom: Error {}

        XCTAssertThrowsError(try store.performWrite { context in
            let mo = NSEntityDescription.insertNewObject(forEntityName: "DiscoveryRunStateMO", into: context) as! DiscoveryRunStateMO
            mo.runID = "run-atomic"
            mo.phaseRaw = DiscoveryRunPhase.preparing.rawValue
            throw Boom()
        })

        XCTAssertNil(try store.runState(runID: "run-atomic"), "回滚后不应残留任何行")

        // 回滚后 store 仍可用
        try store.upsertRunState(freeze: makeFreeze(runID: "run-after"), phase: .preparing, now: fixedNow)
        XCTAssertEqual(try store.runState(runID: "run-after")?.phase, .preparing)
    }

    // MARK: - 冻结往返

    func test_运行状态_冻结十三字段往返与诊断码() throws {
        let store = try makeStore()
        let freeze = makeFreeze()
        try store.upsertRunState(freeze: freeze, phase: .scheduled, now: fixedNow)
        try store.updateRunPhase(
            runID: freeze.runID,
            phase: .backoff,
            diagnostics: [.budgetDeferred, .insufficientCoverage],
            now: fixedNow
        )

        let record = try XCTUnwrap(try store.runState(runID: freeze.runID))
        XCTAssertEqual(record.freeze, freeze, "冻结字段必须逐位一致")
        XCTAssertEqual(record.phase, .backoff)
        XCTAssertEqual(record.diagnostics, [.budgetDeferred, .insufficientCoverage])
    }

    // MARK: - 发布唯一约束

    func test_发布_当前有效发现最多一条且旧条整体删除() throws {
        let store = try makeStore()
        let expiresAt = fixedNow.addingTimeInterval(14 * 24 * 3600)

        let firstID = try store.publishFinding(
            runID: "run-1",
            payload: makePayload(),
            dependencies: [
                .init(sourceRef: "thought:uuid-1", kind: .thought, sourceRevision: "r1", role: .support),
            ],
            publishedAt: fixedNow,
            expiresAt: expiresAt,
            freezeDigest: "d1"
        )
        let first = try XCTUnwrap(try store.activeFinding(now: fixedNow))
        XCTAssertEqual(first.id, firstID)

        // 第二次发布：替换旧条（含依赖行）
        let secondID = try store.publishFinding(
            runID: "run-2",
            payload: makePayload(candidateID: "C02"),
            dependencies: [
                .init(sourceRef: "thought:uuid-9", kind: .thought, sourceRevision: "r9", role: .support),
            ],
            publishedAt: fixedNow.addingTimeInterval(60),
            expiresAt: expiresAt,
            freezeDigest: "d2"
        )
        let second = try XCTUnwrap(try store.activeFinding(now: fixedNow))
        XCTAssertEqual(second.id, secondID)
        XCTAssertEqual(second.payload.candidateID, "C02")

        // 旧条的依赖行已删：按旧 sourceRef 查失效不命中新条
        XCTAssertTrue(try store.findingsAffected(bySourceRefs: ["thought:uuid-1"]).isEmpty)
    }

    // MARK: - 失效依赖查询

    func test_失效依赖查询_反例与统计基线单独标记角色() throws {
        let store = try makeStore()
        let findingID = try store.publishFinding(
            runID: "run-1",
            payload: makePayload(),
            dependencies: [
                .init(sourceRef: "thought:uuid-1", kind: .thought, sourceRevision: "r1", role: .support),
                .init(sourceRef: "thought:uuid-2", kind: .thought, sourceRevision: "r2", role: .support),
                .init(sourceRef: "thought:uuid-3", kind: .thought, sourceRevision: "r3", role: .counterExample),
                .init(sourceRef: "habitEvent:uuid-4", kind: .habitEvent, sourceRevision: "r4", role: .baseline),
            ],
            publishedAt: fixedNow,
            expiresAt: fixedNow.addingTimeInterval(14 * 24 * 3600),
            freezeDigest: "d1"
        )

        // 支持来源变化
        let supportHit = try store.findingsAffected(bySourceRefs: ["thought:uuid-1"])
        XCTAssertEqual(supportHit.first?.findingID, findingID)
        XCTAssertEqual(supportHit.first?.roles, [.support])

        // 反例来源变化（单独标记角色，不是只查支持来源）
        let counterHit = try store.findingsAffected(bySourceRefs: ["thought:uuid-3"])
        XCTAssertEqual(counterHit.first?.roles, [.counterExample])

        // 多来源同时变化合并角色
        let mergedHit = try store.findingsAffected(bySourceRefs: ["thought:uuid-2", "habitEvent:uuid-4"])
        XCTAssertEqual(mergedHit.first?.roles, [.support, .baseline])

        // 无关来源不命中
        XCTAssertTrue(try store.findingsAffected(bySourceRefs: ["thought:uuid-x"]).isEmpty)
    }

    // MARK: - tombstone HMAC

    func test_HMAC指纹_同输入同指纹_不同盐不同密钥不同指纹() {
        let key = SymmetricKey(data: Data(repeating: 0x07, count: 32))
        let otherKey = SymmetricKey(data: Data(repeating: 0x09, count: 32))

        let a = DiscoveryFeedbackFingerprint.compute(material: "subject:lighter-start", key: key, salt: "salt-1")
        let b = DiscoveryFeedbackFingerprint.compute(material: "subject:lighter-start", key: key, salt: "salt-1")
        XCTAssertEqual(a, b, "同输入同盐同密钥必须同指纹")
        XCTAssertEqual(a.count, 64, "SHA-256 hex 长度 64")

        let c = DiscoveryFeedbackFingerprint.compute(material: "subject:lighter-start", key: key, salt: "salt-2")
        XCTAssertNotEqual(a, c, "不同盐必须不同指纹")

        let d = DiscoveryFeedbackFingerprint.compute(material: "subject:lighter-start", key: otherKey, salt: "salt-1")
        XCTAssertNotEqual(a, d, "不同密钥必须不同指纹")

        let e = DiscoveryFeedbackFingerprint.compute(material: "subject:other", key: key, salt: "salt-1")
        XCTAssertNotEqual(a, e, "不同主题必须不同指纹")
    }

    func test_否定反馈_记录命中与显式重置() throws {
        let store = try makeStore()
        try store.recordNegativeFeedback(fingerprintMaterial: "subject:lighter-start", now: fixedNow)
        try store.recordNegativeFeedback(fingerprintMaterial: "subject:lighter-start", now: fixedNow) // 幂等
        XCTAssertTrue(try store.hasNegativeFeedback(fingerprintMaterial: "subject:lighter-start"))
        XCTAssertFalse(try store.hasNegativeFeedback(fingerprintMaterial: "subject:other"))

        try store.resetNegativeFeedback()
        XCTAssertFalse(try store.hasNegativeFeedback(fingerprintMaterial: "subject:lighter-start"))
    }

    // MARK: - 账号清理

    func test_clearAllForAccount_清候选摘录索引在途_保留tombstone() throws {
        let store = try makeStore()
        try store.upsertRunState(freeze: makeFreeze(), phase: .preparing, now: fixedNow)
        try store.recordSourceManifest(runID: "run-1", entries: [
            .init(sourceRef: "thought:uuid-1", kind: .thought, sourceRevision: "r1", fetchedAt: fixedNow),
        ])
        try store.recordRetrievalIndex(runID: "run-1", entries: [
            .init(evidenceID: "E01", sourceRef: "thought:uuid-1", kind: .thought, sourceRevision: "r1", blockHash: "h1"),
        ])
        try store.publishFinding(
            runID: "run-1",
            payload: makePayload(),
            dependencies: [
                .init(sourceRef: "thought:uuid-1", kind: .thought, sourceRevision: "r1", role: .support),
            ],
            publishedAt: fixedNow,
            expiresAt: fixedNow.addingTimeInterval(14 * 24 * 3600),
            freezeDigest: "d1"
        )
        try store.recordNegativeFeedback(fingerprintMaterial: "subject:lighter-start", now: fixedNow)

        try store.clearAllForAccount(now: fixedNow)

        XCTAssertNil(try store.activeFinding(now: fixedNow), "当前发现（含摘录）必须清掉")
        XCTAssertNil(try store.runState(runID: "run-1"), "在途运行状态必须清掉")
        XCTAssertTrue(try store.sourceManifest(runID: "run-1").isEmpty)
        XCTAssertTrue(try store.retrievalIndex(runID: "run-1").isEmpty)
        XCTAssertTrue(try store.activeRuns().isEmpty)
        XCTAssertTrue(try store.hasNegativeFeedback(fingerprintMaterial: "subject:lighter-start"), "否定指纹必须保留")
    }

    // MARK: - 来源清单摘要与内容摘要

    func test_内容摘要_确定性与顺序敏感() {
        let a = DiscoveryContentDigest.sourceRevision(from: ["thought:uuid-1", "正文摘要", "2026-10-01"])
        let b = DiscoveryContentDigest.sourceRevision(from: ["thought:uuid-1", "正文摘要", "2026-10-01"])
        let c = DiscoveryContentDigest.sourceRevision(from: ["2026-10-01", "正文摘要", "thought:uuid-1"])
        XCTAssertEqual(a, b, "同字段序必须同摘要")
        XCTAssertNotEqual(a, c, "字段顺序参与摘要（调用方必须固定字段序）")
        XCTAssertEqual(a.count, 64)
    }

    func test_来源清单摘要_随版本变化() throws {
        let store = try makeStore()
        try store.recordSourceManifest(runID: "run-1", entries: [
            .init(sourceRef: "thought:uuid-1", kind: .thought, sourceRevision: "r1", fetchedAt: fixedNow),
            .init(sourceRef: "task:uuid-2", kind: .task, sourceRevision: "r2", fetchedAt: fixedNow),
        ])
        let digestBefore = try store.sourceManifestDigest(runID: "run-1")

        try store.recordSourceManifest(runID: "run-1", entries: [
            .init(sourceRef: "thought:uuid-1", kind: .thought, sourceRevision: "r1-changed", fetchedAt: fixedNow),
            .init(sourceRef: "task:uuid-2", kind: .task, sourceRevision: "r2", fetchedAt: fixedNow),
        ])
        let digestAfter = try store.sourceManifestDigest(runID: "run-1")

        XCTAssertNotEqual(digestBefore, digestAfter, "来源版本变化必须反映到清单摘要（冻结比对用）")
    }

    // MARK: - 过期与状态

    func test_activeFinding_过期不返回且状态可标记() throws {
        let store = try makeStore()
        let findingID = try store.publishFinding(
            runID: "run-1",
            payload: makePayload(),
            dependencies: [],
            publishedAt: fixedNow,
            expiresAt: fixedNow.addingTimeInterval(3600),
            freezeDigest: "d1"
        )
        XCTAssertNotNil(try store.activeFinding(now: fixedNow.addingTimeInterval(1800)))
        XCTAssertNil(try store.activeFinding(now: fixedNow.addingTimeInterval(7200)), "过期后不再是有效发现")

        try store.markFinding(id: findingID, status: .viewed, now: fixedNow)
        XCTAssertEqual(try store.activeFinding(now: fixedNow)?.status, .viewed)

        try store.invalidateFinding(id: findingID, now: fixedNow)
        XCTAssertNil(try store.activeFinding(now: fixedNow), "已失效不可恢复")
    }
}
