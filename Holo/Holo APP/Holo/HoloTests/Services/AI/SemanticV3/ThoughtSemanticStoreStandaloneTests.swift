import Accelerate
import Foundation
import SQLite3

// V3 Phase 2 standalone：本机语义库（SQLite）+ Flat 索引 + 向量数学的行为锁定。
// USearch 索引实现的行为由 spike（15/15）与主工程编译+模拟器冒烟覆盖。
// 运行：bash scripts/run-thought-semantic-store-standalone.sh

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await ThoughtSemanticStoreStandaloneTests.main()
    }
}
#endif
struct ThoughtSemanticStoreStandaloneTests {
    static func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
        precondition(condition, "check failed: \(message()) (line \(line))")
    }

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-v3-test-\(UUID().uuidString)")
        try await storeLifecycleAndCRUD(tmp)
        try await jobQueueSemantics(tmp)
        try await completedRelationsWithCategoryBriefs(tmp.appendingPathComponent("brief-dedup"))
        try await legacyQueueRecovery(tmp.appendingPathComponent("legacy"))
        await flatIndexBehavior()
        vectorMath()
        try await destroySemantics(tmp)
        try await malformedVectorAndOpenContract(tmp)
        try await followupTableLifecycle(tmp.appendingPathComponent("followup"))
        try await followupQueueAndRetrySemantics(tmp.appendingPathComponent("followup-retry"))
        followupSamplingAndTaskKey()
        try followupContractAgainstFixtures()
        try? FileManager.default.removeItem(at: tmp)
        print("PASS: store生命周期+Float16往返+版本判定+job去重/领取/取消+flat检索正确性+销毁重建+向量数学+R03/R14异常契约")
        print("PASS: 脉络核对三表生命周期（迁移/重启/终态不重算/日额度/保留淘汰/升级失败可回退）")
        print("PASS: 采样/窗口/taskKey/脉络卡纯函数（分层等距/头尾窗口/Jaccard 选段/代理对边界/B2 压制排序）")
        print("PASS: verify-followup 契约对齐真实 fixtures（成功/单对/空/错误封套 + 篡改反证）")
    }

    // MARK: - 1. store 生命周期与 CRUD

    static func storeLifecycleAndCRUD(_ root: URL) async throws {
        let store = await ThoughtSemanticStore(root: root)
        try await store.open()

        let m = try await store.manifest()
        check(m.schemaVersion == ThoughtSemanticStore.schemaVersion && m.nextVectorKey == 1, "默认 manifest")

        // 1024 维归一化向量写入读回（Float16 往返）
        var vector = (0..<1024).map { _ in Float.random(in: -1...1) }
        vector = SemanticVectorMath.normalized(vector)
        let id = UUID()
        let key = try await store.allocateVectorKey()
        let item = ThoughtSemanticStore.SemanticItem(
            id: id, contentHash: "abc123", modelVersion: ThoughtSemanticStore.defaultModelVersion,
            dimension: 1024, vectorKey: key, state: "active", priority: 0,
            lastAccessedAt: nil, updatedAt: Date())
        try await store.upsertItem(item, vector: vector.map(Float16.init))

        let loaded = try await store.loadAllActiveVectors(modelVersion: ThoughtSemanticStore.defaultModelVersion)
        check(loaded.count == 1 && loaded[0].id == id && loaded[0].key == key, "向量行往返")
        var maxErr: Float = 0
        for (a, b) in zip(vector, loaded[0].vector) { maxErr = max(maxErr, abs(a - b)) }
        check(maxErr < 0.005, "Float16 往返误差应 <5e-3，实测 \(maxErr)")

        // 版本判定：同 hash 同模型 → 已完成；不同 hash → 需重算
        check(try await store.hasActiveItem(thoughtID: id, contentHash: "abc123",
                                            modelVersion: ThoughtSemanticStore.defaultModelVersion))
        check(!(try await store.hasActiveItem(thoughtID: id, contentHash: "changed",
                                              modelVersion: ThoughtSemanticStore.defaultModelVersion)))
        check(!(try await store.hasActiveItem(thoughtID: id, contentHash: "abc123", modelVersion: "other-v9")))
        let topicID = UUID()
        try await store.saveTopicProfile(topicID: topicID, contentHash: "definition1", vector: vector)
        let profile = try await store.topicProfile(topicID: topicID, contentHash: "definition1")
        check(profile?.count == 1024, "空主题定义的向量可持久缓存")
        check(try await store.topicProfile(topicID: topicID, contentHash: "definition2") == nil, "修改主题定义后不得复用旧向量")

        // tombstone 后不再算已完成
        try await store.tombstoneItem(thoughtID: id)
        check(!(try await store.hasActiveItem(thoughtID: id, contentHash: "abc123",
                                              modelVersion: ThoughtSemanticStore.defaultModelVersion)), "墓碑后视为未完成")

        // 崩溃恢复语义：新实例同路径重开，数据仍在（SQLite 真身）
        await store.close()
        let reopened = await ThoughtSemanticStore(root: root)
        try await reopened.open()
        let m2 = try await reopened.manifest()
        check(m2.nextVectorKey == key + 1, "重开后 manifest 延续（vectorKey 不回卷）")
    }

    /// 复现「104 条一直待整理」：已有类别理解时，成功回执必须阻止原样重复入队。
    static func completedRelationsWithCategoryBriefs(_ root: URL) async throws {
        let store = await ThoughtSemanticStore(root: root)
        try await store.open()
        let catalogVersion = "thought_semantic_v3.2:catalog:live"
        let topics = (0..<7).map { _ in UUID() }
        for topicID in topics {
            try await store.saveCategoryBrief(.init(topicID: topicID, version: 1,
                definition: "生活中的观察", exclusions: [], basisMemberCount: 5,
                basisRemovalCount: 0, updatedAt: Date()))
        }
        // 旧执行器实际写入的完整指纹；入队端此前只拿 catalogVersion 查询，必然落空。
        let briefKeys = try await store.allCategoryBriefVersionKeys()
        let recordedVersion = catalogVersion + ":brief=" + briefKeys.joined(separator: "|")
        let thoughts = (0..<104).map { _ in UUID() }
        for (i, thoughtID) in thoughts.enumerated() {
            try await store.recordRelationCandidate(thoughtID: thoughtID, topicID: thoughtID,
                contentHash: "unchanged", scoreFeatures: "{}",
                verifierResult: i.isMultiple(of: 2) ? "evaluated" : "no_match",
                state: "evaluated", engineVersion: recordedVersion, expiryDays: 14)
        }
        for pass in 1...3 {
            var requeued = 0
            for thoughtID in thoughts {
                if try await !store.hasRelationRecord(thoughtID: thoughtID, contentHash: "unchanged",
                                                       evaluationVersion: catalogVersion) {
                    requeued += 1
                }
            }
            check(requeued == 0, "第 \(pass) 次核对把 \(requeued)/104 条已整理笔记误判为需要重跑")
        }
        check(!(try await store.hasRelationRecord(thoughtID: thoughts[0], contentHash: "edited",
                                                   evaluationVersion: catalogVersion)), "正文变化仍需重评")
        check(!(try await store.hasRelationRecord(thoughtID: thoughts[0], contentHash: "unchanged",
                                                   evaluationVersion: "new-catalog")), "主题目录变化仍需重评")
        try await store.saveCategoryBrief(.init(topicID: topics[0], version: 2,
            definition: "生活与工作中的观察", exclusions: [], basisMemberCount: 10,
            basisRemovalCount: 0, updatedAt: Date()))
        check(!(try await store.hasRelationRecord(thoughtID: thoughts[0], contentHash: "unchanged",
                                                   evaluationVersion: catalogVersion)), "类别理解升版仍需重评")
        await store.close()
        print("PASS: 7 份类别理解下 104 条完成回执连续三次核对不重排，正文/目录/类别版本变化仍重评")
    }

    // MARK: - 2. job 队列语义

    static func jobQueueSemantics(_ root: URL) async throws {
        let store = await ThoughtSemanticStore(root: root)
        try await store.open()
        let t = UUID()

        func job(_ hash: String, priority: Int = 0, consent: Int64 = 0) -> ThoughtSemanticStore.SemanticJob {
            ThoughtSemanticStore.SemanticJob(id: UUID(), thoughtID: t, contentHash: hash, kind: "embed",
                                             priority: priority, state: "pending", attemptCount: 0,
                                             nextAttemptAt: nil, consentGeneration: consent, lastErrorCode: nil)
        }
        try await store.enqueueJob(job("h1"))
        try await store.enqueueJob(job("h1")) // 同 (thought,hash,kind) 重复入队不产生新行
        check(try await store.hasPendingJob(thoughtID: t, contentHash: "h1", kind: "embed"), "pending 判定")
        check(!(try await store.hasPendingJob(thoughtID: t, contentHash: "h2", kind: "embed")), "不同 hash 不算")

        try await store.enqueueJob(job("h2", priority: 10))
        let claimed = try await store.claimNextDueJob(consentGeneration: 0)
        check(claimed?.contentHash == "h2", "高优先级先领取")
        try await store.finishJob(id: claimed!.id, state: "done")

        // 未来到期时间不领取
        let future = job("h3")
        try await store.enqueueJob(ThoughtSemanticStore.SemanticJob(
            id: future.id, thoughtID: t, contentHash: "h3", kind: "embed", priority: 0, state: "pending",
            attemptCount: 0, nextAttemptAt: Date().addingTimeInterval(3600),
            consentGeneration: 0, lastErrorCode: nil))
        check(try await store.claimNextDueJob(consentGeneration: 0) == nil, "未来任务不领取，旧正文 h1 已取消")

        // 撤权：高于当前 generation 的任务不领取；cancelAll 终态化
        try await store.enqueueJob(job("h4", consent: 5))
        check(try await store.claimNextDueJob(consentGeneration: 1)?.contentHash != "h4", "高 generation 任务不被旧授权领取")
        try await store.cancelAllJobs()
        check(try await store.pendingJobCount() == 0, "cancelAll 后无 pending")
        let interrupted = job("resume", consent: 5)
        try await store.enqueueJob(interrupted)
        let running = try await store.claimNextDueJob(consentGeneration: 5, kind: "embed")
        check(running?.id == interrupted.id)
        await store.close()
        let recovered = await ThoughtSemanticStore(root: root)
        try await recovered.open()
        check(try await recovered.pendingJobCount() == 1, "重启恢复正在执行的任务")
        let restored = try await recovered.claimNextDueJob(consentGeneration: 5, kind: "embed")
        check(restored?.id == interrupted.id, "恢复同一个任务")
        try await recovered.cancelAllJobs()
        let relate = ThoughtSemanticStore.SemanticJob(id: UUID(), thoughtID: t, contentHash: "kinds", kind: "relate", priority: 100, state: "pending", attemptCount: 0, nextAttemptAt: nil, consentGeneration: 5, lastErrorCode: nil)
        try await recovered.enqueueJob(relate)
        check(try await recovered.claimNextDueJob(consentGeneration: 5, kind: "embed") == nil, "embed 不领取 relate")
        check(try await recovered.claimNextDueJob(consentGeneration: 6, kind: "relate") == nil, "旧授权代数不能领取")
        check(try await recovered.claimNextDueJob(consentGeneration: 5, kind: "relate")?.id == relate.id)
        try await recovered.cancelAllJobs()
        // 代数自愈（2026-10-19）：改设置开关递增 generation 后，旧代数 pending 任务
        // re-stamp 恢复可领；running 保持原代数（落库侧防线不动）。
        // enqueueJob 语义=同 thought 同 kind 仅一个在途，用同一 thought 的 embed+relate 两种任务。
        let t2 = UUID()
        let embedRunning = ThoughtSemanticStore.SemanticJob(id: UUID(), thoughtID: t2, contentHash: "h9", kind: "embed", priority: 0, state: "pending", attemptCount: 0, nextAttemptAt: nil, consentGeneration: 5, lastErrorCode: nil)
        let relatePending = ThoughtSemanticStore.SemanticJob(id: UUID(), thoughtID: t2, contentHash: "h9", kind: "relate", priority: 0, state: "pending", attemptCount: 0, nextAttemptAt: nil, consentGeneration: 5, lastErrorCode: nil)
        try await recovered.enqueueJob(embedRunning)
        try await recovered.enqueueJob(relatePending)
        let executing = try await recovered.claimNextDueJob(consentGeneration: 5, kind: "embed")
        check(executing?.id == embedRunning.id, "旧代数下正常领取")
        check(try await recovered.claimNextDueJob(consentGeneration: 7, kind: "relate") == nil, "旧代数 pending 不被新代数领取")
        try await recovered.restampStalePendingJobs(to: 7)
        let revivedJob = try await recovered.claimNextDueJob(consentGeneration: 7, kind: "relate")
        check(revivedJob?.id == relatePending.id, "re-stamp 后 pending 恢复可领")
        check(try await recovered.claimNextDueJob(consentGeneration: 7, kind: "embed") == nil, "running 保持旧代数，不被 re-stamp")
        try await recovered.finishJob(id: executing!.id, state: "cancelled")
        try await recovered.finishJob(id: revivedJob!.id, state: "cancelled")
        try await recovered.recordRelationCandidate(thoughtID: t, topicID: t, contentHash: "eval", scoreFeatures: "{}", verifierResult: "no_match", state: "evaluated", engineVersion: "catalog1", expiryDays: 1)
        check(try await recovered.hasRelationRecord(thoughtID: t, contentHash: "eval", evaluationVersion: "catalog1"))
        check(!(try await recovered.hasRelationRecord(thoughtID: t, contentHash: "eval", evaluationVersion: "catalog2")), "新目录必须重评")
        let waiting = job("wait", consent: 5)
        try await recovered.enqueueJob(waiting)
        _ = try await recovered.claimNextDueJob(consentGeneration: 5, kind: "embed")
        try await recovered.finishJob(id: waiting.id, state: "pending", nextAttemptAt: Date().addingTimeInterval(3600), errorCode: "PRIVACY_ROUTE_UNVERIFIED")
        check(try await recovered.indexStats().waitingReason == "PRIVACY_ROUTE_UNVERIFIED", "服务未开放时展示真实等待原因")
        try await recovered.retryFailedJobs()
        check(try await recovered.claimNextDueJob(consentGeneration: 5, kind: "embed")?.id == waiting.id, "主动重试立即恢复暂时失败的任务")
        try await recovered.cancelAllJobs()
        try await recovered.finishJob(id: waiting.id, state: "pending")
        check(try await recovered.pendingJobCount() == 0, "迟到结果不能恢复已取消的任务")

    }

    // MARK: - 3. Flat 索引检索正确性

    static func legacyQueueRecovery(_ root: URL) async throws {
        let store = await ThoughtSemanticStore(root: root)
        try await store.open()
        let thoughtID = UUID(), jobID = UUID()
        let job = ThoughtSemanticStore.SemanticJob(id: jobID, thoughtID: thoughtID, contentHash: "latest",
            kind: "embed", priority: 0, state: "pending", attemptCount: 1,
            nextAttemptAt: Date().addingTimeInterval(3_600), consentGeneration: 0, lastErrorCode: "RATE_LIMITED")
        try await store.enqueueJob(job)
        await store.close()
        var db: OpaquePointer?
        check(sqlite3_open(root.appendingPathComponent("ThoughtSemanticV3/semantic.sqlite").path, &db) == SQLITE_OK)
        check(sqlite3_exec(db, "DROP INDEX idx_semantic_job_active_unique", nil, nil, nil) == SQLITE_OK)
        // 模拟手机上的旧版重复任务：同一正文累计四个在途记录。
        for _ in 0..<3 {
            check(sqlite3_exec(db, "INSERT INTO semantic_job SELECT randomblob(16),thought_id,content_hash,kind,priority,state,attempt_count,next_attempt_at,consent_generation,last_error_code,finished_at FROM semantic_job LIMIT 1", nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(db)
        let repaired = await ThoughtSemanticStore(root: root)
        try await repaired.open()
        check(try await repaired.pendingJobCount() == 1, "升级必须把四个重复任务恢复为一个")
        check(try await repaired.indexStats().unfinishedThoughts == 1, "状态按笔记数统计")
        let claimed = try await repaired.claimNextDueJob(consentGeneration: 0, kind: "embed")
        check(claimed?.thoughtID == thoughtID && claimed?.nextAttemptAt == nil, "旧的一小时限流等待应立即恢复")
        try await repaired.finishJob(id: claimed!.id, state: "failed_terminal")
        try await repaired.enqueueJob(.init(id: UUID(), thoughtID: thoughtID, contentHash: "newer", kind: "embed",
            priority: 0, state: "pending", attemptCount: 0, nextAttemptAt: nil, consentGeneration: 0, lastErrorCode: nil))
        try await repaired.retryFailedJobs()
        check(try await repaired.pendingJobCount() == 1, "重试不能重新点燃旧正文失败项")
        check(try await repaired.indexStats().failedJobs == 0, "旧正文失败不能混入当前失败数")
        try await repaired.enqueueJob(.init(id: UUID(), thoughtID: thoughtID, contentHash: "newer", kind: "relate",
            priority: 0, state: "pending", attemptCount: 3, nextAttemptAt: Date().addingTimeInterval(3_600),
            consentGeneration: 0, lastErrorCode: "MODEL_OUTPUT_INVALID"))
        await repaired.close()
        let retryRecovery = await ThoughtSemanticStore(root: root)
        try await retryRecovery.open()
        let due = try await retryRecovery.claimNextDueJob(now: Date().addingTimeInterval(61), consentGeneration: 0, kind: "relate")
        check(due?.lastErrorCode == "MODEL_OUTPUT_INVALID", "旧模型格式错误不得继续等待一小时")
        await retryRecovery.close()
    }

    static func flatIndexBehavior() async {
        let index = FlatSemanticIndex()
        var rng = SystemRandomNumberGenerator()
        func unitVector(_ dim: Int) -> [Float] {
            var v = (0..<dim).map { _ in Float(Float64.random(in: -1...1, using: &rng)) }
            return SemanticVectorMath.normalized(v)
        }

        // 100 条 256 维，分 5 个簇
        let centroids = (0..<5).map { _ in unitVector(256) }
        var ids: [UUID] = []
        for i in 0..<100 {
            let id = UUID()
            ids.append(id)
            var v = zip(centroids[i % 5], unitVector(256)).map { $0 * 0.8 + $1 * 0.2 }
            v = SemanticVectorMath.normalized(v)
            try? await index.upsert(id: id, vector: v,
                                    metadata: SemanticIndexMetadata(thoughtID: id, contentHash: "h\(i)",
                                                                    modelVersion: "t", dimension: 256))
        }

        // 用第一个簇心查询：top-5 应全部属于同簇
        let results = (try? await index.search(vector: centroids[0], topK: 5, filter: nil)) ?? []
        check(results.count == 5, "top-5 返回 5 条")
        let topIDs = Set(results.map(\.thoughtID))
        check(topIDs.count == 5 && topIDs.isSubset(of: ids), "命中的都是已插向量")

        // filter 排除 top1 后不再出现
        let excluded = results[0].thoughtID
        let filtered = (try? await index.search(vector: centroids[0], topK: 5,
                                                 filter: SemanticIndexFilter(excludedIDs: [excluded]))) ?? []
        check(!filtered.contains { $0.thoughtID == excluded }, "被排除 id 不出现")

        // remove 后不再命中
        try? await index.remove(id: excluded)
        let afterRemove = (try? await index.search(vector: centroids[0], topK: 100, filter: nil)) ?? []
        check(!afterRemove.contains { $0.thoughtID == excluded }, "已删 id 不命中")
        check(afterRemove.count == 99)

        // 未归一化向量必须拒绝（管线纪律）
        var threw = false
        do { try await index.upsert(id: UUID(), vector: (0..<256).map { _ in Float(1) },
                                    metadata: SemanticIndexMetadata(thoughtID: UUID(), contentHash: "x",
                                                                    modelVersion: "t", dimension: 256)) }
        catch { threw = true }
        check(threw, "未归一化向量应抛错")

        try? await index.destroy()
        let health = (try? await index.validate())!
        check(health.entryCount == 0, "销毁后清空")
    }

    // MARK: - 4. 销毁重建（「删除设备智能索引」入口）

    static func destroySemantics(_ root: URL) async throws {
        let store = await ThoughtSemanticStore(root: root)
        try await store.open()
        let item = ThoughtSemanticStore.SemanticItem(
            id: UUID(), contentHash: "z", modelVersion: "m", dimension: 8, vectorKey: 999,
            state: "active", priority: 0, lastAccessedAt: nil, updatedAt: Date())
        try await store.upsertItem(item, vector: .init(repeating: Float16(0.25), count: 8))
        try await store.destroyAllData()
        let after = try await store.loadAllActiveVectors(modelVersion: "m")
        check(after.isEmpty, "销毁后库为空且句柄可用（重建目录+重开）")
    }

    // MARK: - 5. 向量数学

    static func vectorMath() {
        let v = SemanticVectorMath.normalized([3, 4])
        check(abs(SemanticVectorMath.cosineSimilarity(v, v) - 1) < 0.001, "自相似≈1")
        check(SemanticVectorMath.normalized([0, 0]) == [0, 0], "零向量原样返回")
    }

    // MARK: - 7. 脉络核对三表生命周期（W2，2026-11-16 方案 §6 C3）

    /// 三表迁移/空库/旧库升级/重复 bootstrap/重启/升级失败可回退/终态不重算/保留淘汰。
    static func followupTableLifecycle(_ root: URL) async throws {
        let store = await ThoughtSemanticStore(root: root)
        try await store.open()

        // —— 空库建表 + 重复 bootstrap 幂等 ——
        let scope = UUID(), anchor = UUID()
        let taskKey = "task-\(anchor.uuidString)"
        check(try await store.upsertFollowupTask(taskKey: taskKey, scopeID: scope, anchorID: anchor,
                                                 policyVersion: "thought-followup-1"), "新键入队")
        check(!(try await store.upsertFollowupTask(taskKey: taskKey, scopeID: scope, anchorID: anchor,
                                                   policyVersion: "thought-followup-1")), "在途任务不重复入队")
        await store.close()
        let reopened = await ThoughtSemanticStore(root: root)
        try await reopened.open() // 重复 bootstrap 幂等
        check(!(try await reopened.upsertFollowupTask(taskKey: taskKey, scopeID: scope, anchorID: anchor,
                                                      policyVersion: "thought-followup-1")), "重启后同键仍不重复入队")

        // —— 领取（调用前原子标记）：running + attempt_count+1 + started_day + 运行时限 ——
        let claim1 = try await reopened.claimNextFollowupTask()
        check(claim1?.taskKey == taskKey && claim1?.state == .running, "领取置 running")
        check(claim1?.attemptCount == 1, "领取即计数（调用前原子标记）")
        check(claim1?.startedDay == ThoughtSemanticStore.followupDeviceDay(Date()), "首次尝试落设备日")
        check(claim1?.runDeadline != nil && claim1?.policyVersion == "thought-followup-1", "运行时限与策略版本")

        // —— 输入映射（事务）：全部输入含未进卡片的成员 ——
        let inputs = (0..<5).map { i in
            ThoughtSemanticStore.FollowupSourceRecord(
                taskKey: taskKey, thoughtID: UUID(), scopeID: scope,
                contentHash: "hash\(i)", redactionVersion: "thought_index_v2.1",
                frozenCreatedAt: Date(timeIntervalSince1970: Double(1_767_225_600 + i * 86_400)),
                windows: [.init(ref: "W0", offsetUTF16: 0, lengthUTF16: 20),
                          .init(ref: "W1", offsetUTF16: 600, lengthUTF16: 15)],
                summary: "摘要\(i)")
        }
        try await reopened.recordFollowupSources(inputs)
        let sources = try await reopened.followupSources(taskKey: taskKey)
        check(sources.count == 5 && sources.allSatisfy { $0.scopeID == scope && $0.windows.count == 2 },
              "source 记录全部输入（窗口起点/长度/冻结时间/摘要回读一致）")
        check(sources.contains { $0.contentHash == "hash3" && $0.redactionVersion == "thought_index_v2.1" },
              "正文 hash 与文本处理版本原样回读")

        // —— 成功落库（事务）：verified 终态 + 有界判定数组 + thread ——
        let decisions = [
            ThoughtSemanticStore.FollowupDecisionRecord(
                otherThoughtID: inputs[1].thoughtID, relation: "revises", reason: "把自动决策收紧为高影响时先确认",
                anchorEvidence: .init(thoughtID: anchor, windowRef: "W0", windowOffsetUTF16: 0,
                                      quote: "高影响决定要先确认。", rangeUTF16: [12, 22]),
                otherEvidence: .init(thoughtID: inputs[1].thoughtID, windowRef: "W0", windowOffsetUTF16: 0,
                                     quote: "我原先想让 AI 自动做决定。", rangeUTF16: [0, 15])),
            ThoughtSemanticStore.FollowupDecisionRecord(
                otherThoughtID: inputs[2].thoughtID, relation: "none", reason: nil,
                anchorEvidence: nil, otherEvidence: nil),
        ]
        let threadID = UUID().uuidString
        try await reopened.finishFollowupVerified(
            taskKey: taskKey, decisions: decisions,
            thread: (id: threadID, title: "AI 做决定的边界", question: "哪些决定可以交给 AI 自动执行？",
                     memberIDs: [anchor, inputs[1].thoughtID, inputs[3].thoughtID]))
        let verified = try await reopened.followupResult(taskKey: taskKey)
        check(verified?.state == .verified && verified?.threadID == threadID
              && verified?.decisions.count == 2 && verified?.threadMemberIDs.count == 3
              && verified?.decisions[0].anchorEvidence?.rangeUTF16 == [12, 22], "verified 全字段往返")

        // —— 终态不重算：verified 后同键不入队/不领取（§5 B2）——
        check(try await reopened.hasTerminalFollowup(taskKey: taskKey), "verified 是终态")
        check(!(try await reopened.upsertFollowupTask(taskKey: taskKey, scopeID: scope, anchorID: anchor,
                                                      policyVersion: "thought-followup-1")), "终态键不重算")
        // —— no_result 同为终态 ——
        let scope2 = UUID(), anchor2 = UUID()
        let key2 = "task-\(anchor2.uuidString)"
        try await reopened.upsertFollowupTask(taskKey: key2, scopeID: scope2, anchorID: anchor2, policyVersion: "thought-followup-1")
        _ = try await reopened.claimNextFollowupTask()
        try await reopened.finishFollowupNoResult(taskKey: key2)
        check(try await reopened.hasTerminalFollowup(taskKey: key2), "no_result 是终态")
        check(!(try await reopened.upsertFollowupTask(taskKey: key2, scopeID: scope2, anchorID: anchor2,
                                                      policyVersion: "thought-followup-1")), "no_result 不重算")

        // —— waiting 有界重试：复用 operationId；重试后失败终态 ——
        let anchor3 = UUID()
        let key3 = "task-\(anchor3.uuidString)"
        try await reopened.upsertFollowupTask(taskKey: key3, scopeID: scope, anchorID: anchor3, policyVersion: "thought-followup-1")
        let waitClaim = try await reopened.claimNextFollowupTask()
        check(waitClaim?.taskKey == key3)
        let operationId = waitClaim?.operationID
        try await reopened.finishFollowupWaiting(taskKey: key3, nextAttemptAt: Date().addingTimeInterval(60),
                                                  errorCode: "RATE_LIMITED")
        check(try await reopened.claimNextFollowupTask(now: Date().addingTimeInterval(30)) == nil, "退避未到不领取")
        let retryClaim = try await reopened.claimNextFollowupTask(now: Date().addingTimeInterval(61))
        check(retryClaim?.taskKey == key3 && retryClaim?.attemptCount == 2
              && retryClaim?.operationID == operationId, "到期重试复用 operationId")
        try await reopened.finishFollowupFailed(taskKey: key3, errorCode: "MODEL_OUTPUT_INVALID")
        check(try await reopened.followupResult(taskKey: key3)?.state == .failed, "failed 终态（协议错不进 no_result）")

        // —— 日额度（每日 ≤4 次含重试，§5 B1）：已耗 task=1 + key2=1 + key3=2 = 4 ——
        let anchor4 = UUID()
        let key4 = "task-\(anchor4.uuidString)"
        try await reopened.upsertFollowupTask(taskKey: key4, scopeID: scope, anchorID: anchor4, policyVersion: "thought-followup-1")
        check(try await reopened.followupDailyAttempts() == 4, "日额度按 attempt_count 求和")
        check(try await reopened.claimNextFollowupTask() == nil, "当日额度（含重试）打满后不领取")
        let nextDay = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400 + 60)
        check(try await reopened.claimNextFollowupTask(now: nextDay)?.taskKey == key4, "下个设备日恢复可领")
        try await reopened.finishFollowupFailed(taskKey: key4, errorCode: "CANCEL_TEST")

        // —— 重启恢复：running 回收 waiting（复用 operationId，§6 C2 末条）——
        // （今日 4 次额度已满，用次日时钟领取 key6——额度与恢复语义互不掩盖）
        let anchor6 = UUID()
        let key6 = "task-\(anchor6.uuidString)"
        try await reopened.upsertFollowupTask(taskKey: key6, scopeID: scope, anchorID: anchor6, policyVersion: "thought-followup-1")
        let runningClaim = try await reopened.claimNextFollowupTask(now: nextDay.addingTimeInterval(120))
        check(runningClaim?.taskKey == key6 && runningClaim?.state == .running)
        await reopened.close()
        let afterCrash = await ThoughtSemanticStore(root: root)
        try await afterCrash.open()
        let recovered = try await afterCrash.followupResult(taskKey: key6)
        check(recovered?.state == .waiting && recovered?.operationID == runningClaim?.operationID,
              "崩溃重启：running→waiting 且复用 operationId")
        try await afterCrash.cancelFollowupTasks(scopeID: nil, errorCode: "test_teardown")

        // —— 撤权/范围退出取消：pending/running/waiting 全终态化，cancelled 键可重建 ——
        let anchor5 = UUID()
        let key5 = "task-\(anchor5.uuidString)"
        try await afterCrash.upsertFollowupTask(taskKey: key5, scopeID: scope, anchorID: anchor5, policyVersion: "thought-followup-1")
        try await afterCrash.cancelFollowupTasks(scopeID: scope, errorCode: "consent_revoked")
        check(try await afterCrash.followupResult(taskKey: key5)?.state == .cancelled, "取消终态")
        check(try await afterCrash.claimNextFollowupTask(now: nextDay.addingTimeInterval(180)) == nil,
              "取消后无可领任务（额度有余量时依然无可领行）")
        check(try await afterCrash.upsertFollowupTask(taskKey: key5, scopeID: scope, anchorID: anchor5,
                                                      policyVersion: "thought-followup-1"), "范围重进时 cancelled 键可重建")
        try await afterCrash.cancelFollowupTasks(scopeID: nil, errorCode: "test_teardown")

        // —— 旧库升级：老库（无三表）补建，既有数据不动 ——
        try await afterCrash.close()
        var db: OpaquePointer?
        let dbPath = root.appendingPathComponent("ThoughtSemanticV3/semantic.sqlite")
        check(sqlite3_open(dbPath.path, &db) == SQLITE_OK && db != nil)
        check(sqlite3_exec(db, "DROP TABLE thought_followup_result; DROP TABLE thought_followup_source; DROP TABLE thought_followup_dismissal", nil, nil, nil) == SQLITE_OK, "模拟旧库无三表")
        sqlite3_close(db)
        let upgraded = await ThoughtSemanticStore(root: root)
        try await upgraded.open()
        let probeKey = "task-upgrade-probe"
        check(try await upgraded.upsertFollowupTask(taskKey: probeKey, scopeID: scope, anchorID: UUID(),
                                                    policyVersion: "thought-followup-1"), "升级补建三表且可写")
        // 既有向量/回执不受迁移影响：category_brief 仍可读写
        try await upgraded.saveCategoryBrief(.init(topicID: UUID(), version: 1, definition: "d", exclusions: [],
                                                    basisMemberCount: 0, basisRemovalCount: 0, updatedAt: Date()))
        check(try await upgraded.allCategoryBriefVersionKeys().count == 1, "旧表数据跨升级保留")

        // —— 升级失败可回退：未来 schema 版本拒绝打开且不破坏数据 ——
        await upgraded.close()
        try injectManifestSchemaVersion(dbPath: dbPath, version: 9_999)
        let future = await ThoughtSemanticStore(root: root)
        var threwFuture = false
        do { try await future.open() } catch { threwFuture = true }
        check(threwFuture, "未来 schema 版本必须拒绝打开")
        try injectManifestSchemaVersion(dbPath: dbPath, version: Int64(ThoughtSemanticStore.schemaVersion))
        let rolledBack = await ThoughtSemanticStore(root: root)
        try await rolledBack.open()
        check(try await rolledBack.followupResult(taskKey: probeKey)?.state == .pending, "版本修回后数据无损（可回退）")

        // —— 保留淘汰（§6 C3）：30 天过期清可重建内容、每锚点最新凭证、凭证上限 ——
        try await retentionScenario(rolledBack, scope: scope)

        // —— 隐藏回执：幂等覆盖 + 成员集回读 ——
        let threadA = UUID().uuidString
        let membersA = [UUID(), UUID(), UUID()]
        try await rolledBack.recordFollowupDismissal(scopeID: scope, threadID: threadA, memberIDs: membersA)
        try await rolledBack.recordFollowupDismissal(scopeID: scope, threadID: threadA, memberIDs: membersA + [UUID()])
        let dismissals = try await rolledBack.followupDismissals(scopeID: scope)
        check(dismissals.count == 1 && dismissals[0].memberIDs.count == 4, "dismissal 幂等覆盖")

        // —— 撤权/范围退出清理：结果与来源清空，隐藏回执保留（W3 口径，
        //    §6 C3「日常重算与回滚保留拒绝」；「清除设备索引」走整库销毁才清）——
        let feedbackThought = UUID(), feedbackRelated = UUID()
        try await rolledBack.recordRelatedFeedback(thoughtID: feedbackThought, relatedID: feedbackRelated, basisHash: "h")
        try await rolledBack.destroyFollowupData(scopeID: scope)
        let scopeResultsCleared = try await rolledBack.followupResults(scopeID: scope).isEmpty
        let scopeSourcesCleared = try await rolledBack.followupSources(taskKey: taskKey).isEmpty
        let scopeDismissalsKept = !(try await rolledBack.followupDismissals(scopeID: scope)).isEmpty
        check(scopeResultsCleared && scopeSourcesCleared, "撤权/范围退出清空结果与来源")
        check(scopeDismissalsKept, "隐藏回执保留（拒绝不复活，整库销毁才清本机反馈）")
        check(!(try await rolledBack.relatedFeedbackIDs(thoughtID: feedbackThought)).isEmpty,
              "related_feedback 独立于 followup 清理（相关 pair 拒绝保留）")
        await rolledBack.close()
    }

    /// W3 追加：队列快照/手动重试复位/取消复活/A→B 切换不烧额度/撤权保留 dismissal。
    /// 时序注意：领取会把超时限的 running 行回收回队列（崩溃恢复语义），因此每个
    /// 断言后把领取行终态化清场；「留在途」的行用远期领取时钟使运行时限不超时。
    static func followupQueueAndRetrySemantics(_ root: URL) async throws {
        let store = await ThoughtSemanticStore(root: root)
        try await store.open()
        let base = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        let d2 = base.addingTimeInterval(86_400), d3 = base.addingTimeInterval(2 * 86_400)
        let d4 = base.addingTimeInterval(3 * 86_400), d5 = base.addingTimeInterval(4 * 86_400)
        let farDay = base.addingTimeInterval(10 * 86_400)   // 留途行专用：运行时限不会被测试内时钟超时
        let scopeS = UUID(), scopeO = UUID()

        // —— 1. 队列快照：七种形态 + 范围隔离 ——
        func enqueue(_ key: String, scope: UUID) async throws {
            check(try await store.upsertFollowupTask(taskKey: key, scopeID: scope, anchorID: UUID(),
                                                     policyVersion: "thought-followup-1"), "新键入队 \(key)")
        }
        try await enqueue("q-running", scope: scopeS)
        check(try await store.claimNextFollowupTask(now: farDay)?.taskKey == "q-running", "留途行领取（远期时限不回收）")
        try await enqueue("q-wait-future", scope: scopeS)
        _ = try await store.claimNextFollowupTask(now: base)
        try await store.finishFollowupWaiting(taskKey: "q-wait-future",
                                              nextAttemptAt: base.addingTimeInterval(5 * 86_400),
                                              errorCode: "RATE_LIMITED")           // waiting 未到期
        try await enqueue("q-wait-due", scope: scopeS)
        _ = try await store.claimNextFollowupTask(now: base)
        try await store.finishFollowupWaiting(taskKey: "q-wait-due",
                                              nextAttemptAt: d2.addingTimeInterval(3_600),
                                              errorCode: "RATE_LIMITED")           // waiting：d2 各领取之后、d3 之前到期
        try await enqueue("q-failed", scope: scopeS)
        _ = try await store.claimNextFollowupTask(now: d2)
        try await store.finishFollowupFailed(taskKey: "q-failed", errorCode: "MODEL_OUTPUT_INVALID")
        try await enqueue("q-verified", scope: scopeS)
        _ = try await store.claimNextFollowupTask(now: d2.addingTimeInterval(60))
        try await store.finishFollowupVerified(taskKey: "q-verified", decisions: [], thread: nil)
        try await enqueue("q-no-result", scope: scopeS)
        _ = try await store.claimNextFollowupTask(now: d2.addingTimeInterval(120))
        try await store.finishFollowupNoResult(taskKey: "q-no-result")
        try await enqueue("q-pending", scope: scopeS)
        try await enqueue("q-other-scope", scope: scopeO)

        let statusS = try await store.followupQueueStatus(scopeID: scopeS, now: d3)
        check(statusS.pending == 1 && statusS.running == 1 && statusS.waitingDue == 1
              && statusS.waitingFuture == 1 && statusS.failed == 1 && statusS.verified == 1
              && statusS.noResult == 1, "七形态计数（实测 \(statusS)）")
        check(statusS.inFlight == 4 && statusS.completed == 2, "在途/完成聚合口径")
        let statusO = try await store.followupQueueStatus(scopeID: scopeO, now: d3)
        check(statusO.pending == 1 && statusO.inFlight == 1 && statusO.failed == 0, "快照按范围隔离")

        // —— 2. 手动重试复位：failed + 未到期 waiting → pending；终态/在途不动；
        //        attempt 口径不变（不清零、不占额外额度）——
        let attemptsBefore = try await store.followupDailyAttempts(now: d3)
        let reset = try await store.retryFollowupTasks(scopeID: scopeS, now: d3)
        check(reset == 2, "仅复位 failed 与未到期 waiting（实测 \(reset)）")
        let afterRetry = try await store.followupQueueStatus(scopeID: scopeS, now: d3)
        check(afterRetry.pending == 3 && afterRetry.waitingDue == 1 && afterRetry.waitingFuture == 0
              && afterRetry.failed == 0 && afterRetry.verified == 1 && afterRetry.noResult == 1
              && afterRetry.running == 1, "复位后仅 pending 增、到期等待与终态/在途不动")
        let revivedFailed = try await store.followupResult(taskKey: "q-failed")
        check(revivedFailed?.attemptCount == 1 && revivedFailed?.lastErrorCode == nil,
              "attempt_count 保留、错误码清空")
        check(try await store.followupDailyAttempts(now: d3) == attemptsBefore,
              "复位本身不消耗当日额度（领取处才计）")
        let firstClaim = try await store.claimNextFollowupTask(now: d3)
        check(firstClaim?.taskKey == "q-wait-future" && firstClaim?.attemptCount == 2,
              "复位行立即按序领取，attempt 延续计数")
        try await store.finishFollowupNoResult(taskKey: "q-wait-future")   // 清场
        let dueClaim = try await store.claimNextFollowupTask(now: d3.addingTimeInterval(60))
        check(dueClaim?.taskKey == "q-wait-due", "到期等待行不在复位范围、本就可领（按创建序）")
        try await store.finishFollowupNoResult(taskKey: "q-wait-due")      // 清场

        // —— 3. 取消复活：cancelled 行 upsert 复位回 pending（新 operationId/attempt 归零）——
        try await store.cancelFollowupTasks(scopeID: scopeO, errorCode: "consent_revoked")
        check(try await store.followupResult(taskKey: "q-other-scope")?.state == .cancelled, "取消终态")
        let originalOperation = try await store.followupResult(taskKey: "q-other-scope")?.operationID
        check(try await store.upsertFollowupTask(taskKey: "q-other-scope", scopeID: scopeO, anchorID: UUID(),
                                                 policyVersion: "thought-followup-1"), "cancelled 键可复活")
        let revived = try await store.followupResult(taskKey: "q-other-scope")
        check(revived?.state == .pending && revived?.attemptCount == 0 && revived?.startedDay == nil
              && revived?.operationID != originalOperation, "复活 = 新生命周期（pending/attempt 归零/新 operationId）")
        // 追清剩余 pending（q-failed/q-pending/q-other-scope），验证复活行可被领取
        let drain1 = try await store.claimNextFollowupTask(now: d4)
        check(drain1?.taskKey == "q-failed", "复位 failed 行按创建序先领")
        try await store.finishFollowupNoResult(taskKey: "q-failed")        // 清场
        let drain2 = try await store.claimNextFollowupTask(now: d4.addingTimeInterval(60))
        check(drain2?.taskKey == "q-pending", "未触碰的 pending 行照常领取")
        try await store.finishFollowupNoResult(taskKey: "q-pending")       // 清场
        let drain3 = try await store.claimNextFollowupTask(now: d4.addingTimeInterval(120))
        check(drain3?.taskKey == "q-other-scope" && drain3?.attemptCount == 1,
              "复活行进入正常领取（attempt 从 1 重新计）")
        try await store.finishFollowupNoResult(taskKey: "q-other-scope")   // 清场

        // —— 4. A→B 切换：旧 scope 未终态直接取消，不烧额度、不逐拍排干 ——
        let scopeA = UUID(), scopeB = UUID()
        try await store.upsertFollowupTask(taskKey: "qa-running", scopeID: scopeA, anchorID: UUID(), policyVersion: "p")
        _ = try await store.claimNextFollowupTask(now: d4.addingTimeInterval(180))  // qa-running（唯一 pending，领走置 running）
        try await store.upsertFollowupTask(taskKey: "qa-pending", scopeID: scopeA, anchorID: UUID(), policyVersion: "p")
        try await store.upsertFollowupTask(taskKey: "qb-pending", scopeID: scopeB, anchorID: UUID(), policyVersion: "p")
        try await store.cancelFollowupTasksOutsideScope(keep: scopeB)
        let qaPending = try await store.followupResult(taskKey: "qa-pending")
        let qaRunning = try await store.followupResult(taskKey: "qa-running")
        check(qaPending?.state == .cancelled && qaRunning?.state == .cancelled
              && qaPending?.attemptCount == 0 && qaRunning?.attemptCount == 1,
              "旧 scope 未终态行取消终态且 attempt 不被额外消耗")
        check(try await store.followupResult(taskKey: "qb-pending")?.state == .pending, "保留 scope 在途行不动")
        check(try await store.claimNextFollowupTask(now: d5)?.taskKey == "qb-pending",
              "旧 scope 行不再被逐拍领取（下一拍直接领新 scope）")

        // —— 5. 撤权保留 dismissal；清除设备索引（整库销毁）才清本机反馈 ——
        let threadID = UUID().uuidString
        try await store.recordFollowupDismissal(scopeID: scopeA, threadID: threadID,
                                                memberIDs: [UUID(), UUID(), UUID()])
        try await store.destroyFollowupData(scopeID: scopeA)
        let dismissalsKept = try await store.followupDismissals(scopeID: scopeA)
        check((try await store.followupResults(scopeID: scopeA)).isEmpty && dismissalsKept.count == 1,
              "撤权清结果/来源、隐藏回执保留")
        try await store.destroyAllData()
        check(try await store.followupDismissals(scopeID: scopeA).isEmpty, "整库销毁清掉本机反馈")
        await store.close()
        print("PASS: W3 队列快照/手动重试复位/取消复活/A→B 切换不烧额度/撤权保留 dismissal")
    }

    /// 保留淘汰场景（参数注入小阈值验证真实 SQL 语义）。
    private static func retentionScenario(_ store: ThoughtSemanticStore, scope: UUID) async throws {
        let now = Date()
        // 锚点 A：两条终态（新旧行）。旧行超 30 天 → 内容清空后再按「每锚点最新」整行删除
        let anchorA = UUID()
        let oldKey = "ret-old-\(anchorA.uuidString)", newKey = "ret-new-\(anchorA.uuidString)"
        for (key, verifiedAt) in [(oldKey, now.addingTimeInterval(-40 * 86_400)), (newKey, now)] {
            try await store.upsertFollowupTask(taskKey: key, scopeID: scope, anchorID: anchorA, policyVersion: "p")
            _ = try await store.claimNextFollowupTask()
            try await store.finishFollowupVerified(
                taskKey: key,
                decisions: [ThoughtSemanticStore.FollowupDecisionRecord(
                    otherThoughtID: UUID(), relation: "continues", reason: "r",
                    anchorEvidence: nil, otherEvidence: nil)],
                thread: (id: UUID().uuidString, title: "t", question: "q?", memberIDs: [UUID(), UUID(), UUID()]),
                now: verifiedAt)
        }
        try await store.recordFollowupSources([.init(taskKey: oldKey, thoughtID: UUID(), scopeID: scope,
                                                     contentHash: "h", redactionVersion: "r",
                                                     frozenCreatedAt: now, windows: [], summary: "s")])
        // 锚点 B/C：各一条近期终态；凭证上限注入 1 → 淘汰最旧锚点组（保留 anchorA 最新）
        var staleAnchorKeys: [String] = []
        for anchor in [UUID(), UUID()] {
            let key = "ret-\(anchor.uuidString)"
            staleAnchorKeys.append(key)
            try await store.upsertFollowupTask(taskKey: key, scopeID: scope, anchorID: anchor, policyVersion: "p")
            _ = try await store.claimNextFollowupTask()
            try await store.finishFollowupNoResult(taskKey: key, now: now.addingTimeInterval(-3 * 86_400))
        }
        try await store.pruneFollowupRetention(scopeID: scope, now: now, maxAgeDays: 30,
                                               maxBatchesPerScope: 200, maxAnchorReceipts: 1)
        check(try await store.followupResult(taskKey: oldKey) == nil, "同锚点旧终态行删除（只留最新凭证）")
        let kept = try await store.followupResult(taskKey: newKey)
        check(kept?.state == .verified && kept?.decisions.count == 1 && kept?.threadTitle == "t",
              "最新完成凭证保留（判定与 thread 未过期不清）")
        for key in staleAnchorKeys {
            check(try await store.followupResult(taskKey: key) == nil, "凭证上限淘汰最旧锚点组")
        }
        check(try await store.followupSources(taskKey: oldKey).isEmpty, "过期行的 source 窗口一并清理")

        // 30 天过期但无同锚点新行：内容清空、凭证行保留（先隐藏再清可重建内容）
        let anchorD = UUID()
        let agedKey = "ret-aged-\(anchorD.uuidString)"
        try await store.upsertFollowupTask(taskKey: agedKey, scopeID: scope, anchorID: anchorD, policyVersion: "p")
        _ = try await store.claimNextFollowupTask()
        try await store.finishFollowupVerified(
            taskKey: agedKey,
            decisions: [ThoughtSemanticStore.FollowupDecisionRecord(
                otherThoughtID: UUID(), relation: "contrasts", reason: "r", anchorEvidence: nil, otherEvidence: nil)],
            thread: (id: UUID().uuidString, title: "旧脉络", question: "q?", memberIDs: [UUID(), UUID(), UUID()]),
            now: now.addingTimeInterval(-35 * 86_400))
        try await store.recordFollowupSources([.init(taskKey: agedKey, thoughtID: UUID(), scopeID: scope,
                                                     contentHash: "h2", redactionVersion: "r",
                                                     frozenCreatedAt: now, windows: [], summary: "s2")])
        try await store.pruneFollowupRetention(scopeID: scope, now: now, maxAgeDays: 30,
                                               maxBatchesPerScope: 200, maxAnchorReceipts: 120)
        let aged = try await store.followupResult(taskKey: agedKey)
        check(aged?.state == .verified && aged?.threadTitle == nil && aged?.decisions.isEmpty == true,
              "超龄先清可重建内容（凭证行保留防重调）")
        check(try await store.followupSources(taskKey: agedKey).isEmpty, "超龄 source 同步清理")
        // 凭证仍在：同键不入队（只因过期/清理不重试同一个键，§6 C3）
        check(!(try await store.upsertFollowupTask(taskKey: agedKey, scopeID: scope, anchorID: anchorD,
                                                   policyVersion: "p")), "过期凭证仍阻止重算同键")
    }

    /// 直接改 manifest 版本（模拟「升级失败/未来版本」的库）。
    private static func injectManifestSchemaVersion(dbPath: URL, version: Int64) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            preconditionFailure("manifest 注入库打不开")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE semantic_manifest SET schema_version=?1 WHERE id=1", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            preconditionFailure("manifest 注入 prepare 失败")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, version)
        guard sqlite3_step(stmt) == SQLITE_DONE else { preconditionFailure("manifest 注入失败") }
    }

    // MARK: - 8. 采样/窗口/taskKey/脉络卡纯函数（§5 B1/B2）

    static func followupSamplingAndTaskKey() {
        func note(_ id: Int, daysAgo: Double, text: String, hash: String? = nil, vector: [Float]? = nil) -> ThoughtFollowupSampling.NoteSnapshot {
            .init(thoughtID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
                  createdAt: Date(timeIntervalSinceNow: -daysAgo * 86_400),
                  contentHash: hash ?? "h\(id)", redactedText: text, vector: vector)
        }
        let unit: [Float] = { var v = [Float](repeating: 0.5, count: 8); v[0] = 1; return v }()

        // —— 分层等距：130 条 → 各段 ≤40、首尾保留 ——
        let pool = (0..<130).map { note($0, daysAgo: Double($0), text: "成员正文\($0)") }
        let segmented = ThoughtFollowupSampling.segmentedPool(pool)
        check(segmented.early.count <= 40 && segmented.middle.count <= 40 && segmented.recent.count <= 40,
              "三段各 ≤40（实测 \(segmented.early.count)/\(segmented.middle.count)/\(segmented.recent.count)）")
        check(segmented.early.count + segmented.middle.count + segmented.recent.count <= 120, "入池 ≤120")
        check(segmented.early.first?.thoughtID == pool.last?.thoughtID
              && segmented.recent.last?.thoughtID == pool.first?.thoughtID,
              "整池首尾成员保留（最早在 early 首、最新在 recent 尾）")
        let slice = ThoughtFollowupSampling.sampleMemberSlice(pool.map { ($0.thoughtID, $0.createdAt) })
        check(slice.recent.count == segmented.recent.count && slice.early.count == segmented.early.count,
              "轻量分层与快照分层同规则")

        // —— 窗口：短文单窗全文；长文锚点头尾两窗不重叠 ——
        let shortText = "短想法，一整段就够。"
        let shortNote = note(1, daysAgo: 0, text: shortText)
        let shortWindows = ThoughtFollowupSampling.windows(for: shortNote, isAnchor: true)
        check(shortWindows.count == 1 && shortWindows[0].text == shortText && shortWindows[0].offsetUTF16 == 0,
              "短文取连续全文单窗口")
        let longTail = String(repeating: "结论在末尾的旧证据。", count: 60)
        let longText = String(repeating: "开头介绍背景。", count: 60) + longTail
        check(longText.utf16.count > 1_000, "长文前提（实际 \(longText.utf16.count) UTF-16）")
        let anchorNote = note(2, daysAgo: 1, text: longText)
        let anchorWindows = ThoughtFollowupSampling.windows(for: anchorNote, isAnchor: true)
        check(anchorWindows.count == 2 && anchorWindows[0].lengthUTF16 <= 600 && anchorWindows[1].lengthUTF16 <= 600,
              "锚点头尾两窗各 ≤600")
        check(anchorWindows[0].offsetUTF16 == 0
              && anchorWindows[1].offsetUTF16 + anchorWindows[1].lengthUTF16 == longText.utf16.count,
              "锚点尾窗贴到文末（不截断代理对）")
        check(anchorWindows[1].offsetUTF16 >= anchorWindows[0].lengthUTF16, "两窗不重叠")

        // —— 长文非锚点：头部固定 + Jaccard 选段；无命中用末段 ——
        let matching = String(repeating: "结论在末尾的旧证据。", count: 50)
        let nonAnchorText = String(repeating: "别的主题内容。", count: 50) + matching
        let nonAnchor = note(3, daysAgo: 2, text: nonAnchorText)
        let references = ThoughtFollowupSampling.anchorReferences(anchor: anchorNote)
        let picked = ThoughtFollowupSampling.windows(for: nonAnchor, isAnchor: false,
                                                     anchorHead: references.head, anchorTail: references.tail)
        check(picked.count == 2 && picked[1].text.contains("结论在末尾的旧证据"), "Jaccard 命中选中有重叠的段落")
        let noHit = note(4, daysAgo: 3, text: String(repeating: "完全不相关的内容甲乙丙。", count: 80))
        let pickedNoHit = ThoughtFollowupSampling.windows(for: noHit, isAnchor: false,
                                                          anchorHead: references.head, anchorTail: references.tail)
        check(pickedNoHit.count == 2
              && pickedNoHit[1].offsetUTF16 + pickedNoHit[1].lengthUTF16 == noHit.redactedText.utf16.count,
              "无命中用末段且贴到文末")

        // —— 代理对不截断：600 边界落在代理对中间（"X" + 305 emoji = 611 UTF-16）——
        let emojiText = "X" + String(repeating: "😀", count: 305)
        let emojiNote = note(5, daysAgo: 4, text: emojiText)
        let emojiWindows = ThoughtFollowupSampling.windows(for: emojiNote, isAnchor: false,
                                                           anchorHead: "😀", anchorTail: "😀")
        check(emojiWindows.count == 2
              && emojiWindows[0].offsetUTF16 + emojiWindows[0].lengthUTF16 <= emojiWindows[1].offsetUTF16,
              "边界回退后两窗仍不重叠")
        check(emojiWindows[1].offsetUTF16 + emojiWindows[1].lengthUTF16 == emojiText.utf16.count,
              "尾段贴到文末")
        check(emojiWindows[1].text.hasPrefix("😀") && emojiWindows[1].text.utf16.count % 2 == 0,
              "第二窗口以完整代理对开始（不截断）")

        // —— 召回：同 hash/拒绝 pair/低相似度过滤；较早+中段保底；≤4 ——
        var near = unit; near[1] = 0.9
        let anchorForRecall = note(10, daysAgo: 100, text: "锚点正文", vector: unit)
        let earlyHit = note(11, daysAgo: 90, text: "较早的相似笔记", vector: near)
        let middleHit = note(12, daysAgo: 50, text: "中段的相似笔记", vector: near)
        let recentHits = (0..<5).map { note(20 + $0, daysAgo: Double($0), text: "较新的相似笔记\($0)", vector: near) }
        let lowScore = note(30, daysAgo: 1, text: "不相似的笔记", vector: { var v = unit; v[0] = -1; return v }())
        let sameHash = note(31, daysAgo: 2, text: "相同正文", hash: anchorForRecall.contentHash, vector: near)
        let rejectedID = recentHits[4].thoughtID
        let recalled = ThoughtFollowupSampling.recallCandidates(
            anchor: anchorForRecall,
            early: [earlyHit, lowScore, sameHash],
            middle: [middleHit],
            recent: recentHits,
            rejectedPairIDs: [rejectedID],
            minCosine: 0.55)
        check(recalled.count == 4, "召回 ≤4（实测 \(recalled.count)）")
        check(recalled.contains(where: { $0.thoughtID == earlyHit.thoughtID })
              && recalled.contains(where: { $0.thoughtID == middleHit.thoughtID }), "较早与中段各保底一名")
        check(!recalled.contains(where: { $0.thoughtID == lowScore.thoughtID })
              && !recalled.contains(where: { $0.thoughtID == sameHash.thoughtID })
              && !recalled.contains(where: { $0.thoughtID == rejectedID }), "低相似度/同 hash/拒绝 pair 全部排除")

        // —— taskKey：输入决定、顺序无关、版本敏感 ——
        let scopeID = UUID(), anchorID = UUID()
        let entryA = (thoughtID: UUID(), contentHash: "ha", windows: [
            ThoughtFollowupSampling.Window(ref: "W0", offsetUTF16: 0, text: "甲"),
            ThoughtFollowupSampling.Window(ref: "W1", offsetUTF16: 600, text: "乙")])
        let entryB = (thoughtID: UUID(), contentHash: "hb", windows: [
            ThoughtFollowupSampling.Window(ref: "W0", offsetUTF16: 0, text: "丙")])
        let key1 = ThoughtFollowupSampling.taskKey(scopeID: scopeID, anchorID: anchorID, notes: [entryA, entryB],
                                                   policyVersion: "thought-followup-1",
                                                   redactionVersion: "r1", embeddingModelVersion: "m1")
        let key2 = ThoughtFollowupSampling.taskKey(scopeID: scopeID, anchorID: anchorID, notes: [entryB, entryA],
                                                   policyVersion: "thought-followup-1",
                                                   redactionVersion: "r1", embeddingModelVersion: "m1")
        check(key1 == key2 && key1.count == 64, "taskKey 输入顺序无关（sorted 编码）")
        let key3 = ThoughtFollowupSampling.taskKey(scopeID: scopeID, anchorID: anchorID, notes: [entryA, entryB],
                                                   policyVersion: "thought-followup-2",
                                                   redactionVersion: "r1", embeddingModelVersion: "m1")
        check(key1 != key3, "policyVersion 变化另起新键")

        // —— 脉络卡形成（B2）——
        let m1 = [UUID(), UUID(), UUID()], m2 = [UUID(), UUID(), UUID(), UUID()], m3 = [UUID(), UUID(), UUID(), UUID(), UUID()]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let cards = ThoughtFollowupSampling.formThreadCards(
            candidates: [
                .init(displayID: "d1", memberIDs: Set(m1), supportCount: 3, latestEvidenceAt: base),
                // 完全相同成员集：共用展示 ID，保留最近版本
                .init(displayID: "d1-old", memberIDs: Set(m1), supportCount: 3, latestEvidenceAt: base.addingTimeInterval(100)),
                // 与 m2 交集 4、Jaccard=4/5=0.8 ≥0.6 → 疑似重复压制（m2 支持数更高排前）
                .init(displayID: "d2", memberIDs: Set(m2), supportCount: 4, latestEvidenceAt: base.addingTimeInterval(50)),
                .init(displayID: "d3", memberIDs: Set(m3), supportCount: 5, latestEvidenceAt: base.addingTimeInterval(50)),
                // 支持数不足 3 → 不成卡
                .init(displayID: "d4", memberIDs: [UUID(), UUID()], supportCount: 2, latestEvidenceAt: base),
            ],
            dismissals: [])
        check(cards.count == 2, "每主题至多 2 张（实测 \(cards.count)）")
        check(cards[0].displayID == "d3" && cards[1].displayID == "d2", "排序=支持数→证据时间→稳定 ID，疑似重复 d1-old 已压制")
        check(!cards.contains { $0.displayID == "d1-old" }, "相同成员集共用展示 ID（取最近版本）")
        // 隐藏压制：按展示 ID 与重叠条件（§5 B2）
        let afterDismiss = ThoughtFollowupSampling.formThreadCards(
            candidates: [.init(displayID: "d3", memberIDs: Set(m3), supportCount: 5, latestEvidenceAt: base)],
            dismissals: [.init(displayID: "other-id", memberIDs: Set(m3))])
        check(afterDismiss.isEmpty, "与已隐藏卡高重叠的新脉络被压制")
    }

    // MARK: - 9. verify-followup 契约对齐真实 fixtures（§6 C2 / R29）

    /// fixtures 目录由源码路径推导（standalone 与主工程同源编译均可定位）。
    static var fixturesDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "HOLO" && url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("docs/thoughts/plans/2026-11-16-想法主题与脉络/fixtures")
    }

    /// 与后端 804a96c6b 提交的真实响应 fixture（spec C2 示例的三笔记输入）逐字段对齐。
    static func followupContractAgainstFixtures() throws {
        let decoder = JSONDecoder()
        let idByRef = ["N0": UUID(), "N1": UUID(), "N2": UUID()]
        let windowOffsets = ["N0": ["W0": 0], "N1": ["W0": 0], "N2": ["W0": 0]]

        func specRequest(operationId: String) -> ThoughtFollowupRequestDTO {
            // §6 C2 请求示例（与成功 fixture 的 evidence 逐字对应）
            guard let request = ThoughtFollowupValidator.makeRequest(
                operationId: operationId,
                scopeTitle: "产品思考",
                anchorRef: "N2",
                notes: [
                    ("N0", 1_767_225_600_000, [("W0", "我原先想让 AI 自动做决定。")]),
                    ("N1", 1_769_904_000_000, [("W0", "我发现自动决定出了错难以纠正。")]),
                    ("N2", 1_772_323_200_000, [("W0", "我修改了自动决定的原则。高影响决定要先确认。")]),
                ]) else {
                preconditionFailure("spec 请求组装失败")
            }
            return request
        }

        // —— 成功（thread）：verified，成员/证据/关系映射全对 ——
        let threadData = try Data(contentsOf: fixturesDirectory.appendingPathComponent("verify-followup-success-thread.json"))
        let threadResponse = try decoder.decode(ThoughtFollowupResponseDTO.self, from: threadData)
        let request = specRequest(operationId: threadResponse.operationId)
        guard case .verified(let content) = ThoughtFollowupValidator.validate(
            response: threadResponse, request: request, noteIDByRef: idByRef, windowOffsetByNoteRef: windowOffsets) else {
            preconditionFailure("success-thread fixture 必须通过校验")
        }
        check(content.decisions.count == 2
              && content.decisions[0].relation == "revises" && content.decisions[1].relation == "continues",
              "成立关系逐条核对（fixture 逐字回窗通过）")
        check(content.decisions[1].anchorEvidence?.rangeUTF16 == [12, 22]
              && content.decisions[1].anchorEvidence?.quote == "高影响决定要先确认。", "锚点窗口内子区间引用")
        check(content.thread?.memberThoughtIDs == [idByRef["N2"]!, idByRef["N0"]!, idByRef["N1"]!],
              "thread 成员 3–5 含锚点并映射回本机 ID")
        check(content.hasEstablishedRelation, "成立关系存在")

        // —— 成功（单对）：verified、thread 为 nil（相关区可用，脉络仍空）——
        let singleData = try Data(contentsOf: fixturesDirectory.appendingPathComponent("verify-followup-success-single-pair.json"))
        let singleResponse = try decoder.decode(ThoughtFollowupResponseDTO.self, from: singleData)
        guard case .verified(let single) = ThoughtFollowupValidator.validate(
            response: singleResponse, request: specRequest(operationId: singleResponse.operationId),
            noteIDByRef: idByRef, windowOffsetByNoteRef: windowOffsets) else {
            preconditionFailure("single-pair fixture 必须通过校验")
        }
        check(single.thread == nil && single.hasEstablishedRelation, "单对成立：相关区可用，主题脉络为空")

        // —— 成功（空）：全部非命中 → no_result 终态 ——
        let emptyData = try Data(contentsOf: fixturesDirectory.appendingPathComponent("verify-followup-success-empty.json"))
        let emptyResponse = try decoder.decode(ThoughtFollowupResponseDTO.self, from: emptyData)
        guard case .noResult = ThoughtFollowupValidator.validate(
            response: emptyResponse, request: specRequest(operationId: emptyResponse.operationId),
            noteIDByRef: idByRef, windowOffsetByNoteRef: windowOffsets) else {
            preconditionFailure("empty fixture 必须判 no_result")
        }

        // —— 错误封套：decisions 缺失 → 客户端按错误路径处理（不进校验器）——
        for errorFixture in ["verify-followup-disabled.json", "verify-followup-input-too-large.json",
                             "verify-followup-model-output-invalid.json", "verify-followup-rate-limited.json"] {
            let data = try Data(contentsOf: fixturesDirectory.appendingPathComponent(errorFixture))
            check((try? decoder.decode(ThoughtFollowupResponseDTO.self, from: data)) == nil,
                  "错误封套不是 200 形状（\(errorFixture)）")
        }

        // —— 篡改反证（R29：注入错字段必须失败）——
        func stillVerified(_ copy: ThoughtFollowupResponseDTO) -> Bool {
            if case .verified = ThoughtFollowupValidator.validate(
                response: copy, request: request, noteIDByRef: idByRef, windowOffsetByNoteRef: windowOffsets) {
                return true
            }
            return false
        }
        var tampered = threadResponse
        tampered.operationId = UUID().uuidString
        check(!stillVerified(tampered), "operationId 不一致必须拒绝")
        tampered = threadResponse
        tampered.policyVersion = "thought-followup-2"
        check(!stillVerified(tampered), "policyVersion 不一致必须拒绝")
        tampered = threadResponse
        tampered.decisions[0].anchorEvidence?.quote = "我原先想让 AI 自动做决定。"
        check(!stillVerified(tampered), "跨窗/错位引用必须拒绝")
        tampered = threadResponse
        tampered.decisions[0].anchorEvidence?.rangeUTF16 = [0, 999]
        check(!stillVerified(tampered), "范围越窗必须拒绝")
        tampered = threadResponse
        tampered.decisions[1].relation = "none"
        check(!stillVerified(tampered), "thread 成员失去成立关系必须拒绝")
        tampered = threadResponse
        tampered.decisions[0].reason = nil
        check(!stillVerified(tampered), "成立关系缺 reason 必须拒绝")
        tampered = threadResponse
        tampered.decisions = Array(tampered.decisions.prefix(1))
        check(!stillVerified(tampered), "决定不完整必须拒绝")
        tampered = threadResponse
        tampered.thread?.memberRefs = ["N0", "N1", "N9"]
        check(!stillVerified(tampered), "自造 ref 必须拒绝")
        // none/insufficient 三字段全 null 的负向判定合法
        var negative = threadResponse
        negative.thread = nil
        negative.decisions[1].relation = "insufficient"
        negative.decisions[1].reason = nil
        negative.decisions[1].anchorEvidence = nil
        negative.decisions[1].otherEvidence = nil
        if case .verified(let mixed) = ThoughtFollowupValidator.validate(
            response: negative, request: request, noteIDByRef: idByRef, windowOffsetByNoteRef: windowOffsets) {
            check(mixed.decisions[1].relation == "insufficient" && mixed.thread == nil, "混合结果合法（一成立一不足）")
        } else {
            check(false, "合法混合结果不得误判协议错")
        }

        // —— 请求界限（本地自查，防白打）——
        check(ThoughtFollowupValidator.makeRequest(
            operationId: UUID().uuidString, scopeTitle: "产品思考", anchorRef: "N0",
            notes: [("N0", 0, [("W0", String(repeating: "字", count: 601))])]) == nil, "窗口超 600 拒绝")
        check(ThoughtFollowupValidator.makeRequest(
            operationId: UUID().uuidString, scopeTitle: "产品思考", anchorRef: "N0",
            notes: (0..<6).map { ("N\($0)", 0, [("W0", "文本\($0)")]) }) == nil, "notes 超 5 拒绝")
        check(ThoughtFollowupValidator.makeRequest(
            operationId: UUID().uuidString, scopeTitle: "产品思考", anchorRef: "N8",
            notes: [("N0", 0, [("W0", "a")]), ("N9", 0, [("W0", "b")])]) == nil, "anchorRef 不在 notes 拒绝")
        check(ThoughtFollowupValidator.makeRequest(
            operationId: UUID().uuidString, scopeTitle: "产品思考", anchorRef: "N0",
            notes: [("N0", 0, [("W0", String(repeating: "段", count: 600)), ("W1", String(repeating: "续", count: 600))]),
                    ("N1", 0, [("W0", String(repeating: "乙", count: 600)), ("W1", String(repeating: "加", count: 600))]),
                    ("N2", 0, [("W0", String(repeating: "丙", count: 600)), ("W1", String(repeating: "丁", count: 600))]),
                    ("N3", 0, [("W0", String(repeating: "戊", count: 600)), ("W1", String(repeating: "己", count: 600))]),
                    ("N4", 0, [("W0", String(repeating: "庚", count: 600)), ("W1", String(repeating: "辛", count: 600))])]) != nil,
              "5×2×600=6000 恰在总量上限内（含等号，与后端 totalText > 6000 拒绝对齐）")
        check(ThoughtFollowupValidator.makeRequest(
            operationId: "not-a-uuid", scopeTitle: "产品思考", anchorRef: "N0",
            notes: [("N0", 0, [("W0", "文本")]), ("N1", 0, [("W0", "文本")])]) != nil,
              "operationId 非空字符串客户端不校验 UUID 形状（后端裁决）——本组输入合法")
    }

    static func malformedVectorAndOpenContract(_ root: URL) async throws {
        // —— R03 写入契约：维度为正数且等于向量元素数，先校验后落库 ——
        let store = await ThoughtSemanticStore(root: root)
        try await store.open()
        let key = try await store.allocateVectorKey()
        let id = UUID()
        func draft(dim: Int) -> ThoughtSemanticStore.SemanticItem {
            ThoughtSemanticStore.SemanticItem(id: id, contentHash: "contract", modelVersion: "m",
                                              dimension: dim, vectorKey: key, state: "active",
                                              priority: 0, lastAccessedAt: nil, updatedAt: Date())
        }
        var threw = false
        do { try await store.upsertItem(draft(dim: 4), vector: .init(repeating: Float16(1), count: 3)) }
        catch { threw = true }
        check(threw, "维度与向量元素数不一致必须抛错")
        threw = false
        do { try await store.upsertItem(draft(dim: 0), vector: []) }
        catch { threw = true }
        check(threw, "非正维度必须抛错")
        check(try await store.loadAllActiveVectors(modelVersion: "m").isEmpty, "被拒数据不得落库")
        // 合法写入对照：契约只拦坏数据，不伤正常路径
        try await store.upsertItem(draft(dim: 4), vector: .init(repeating: Float16(0.5), count: 4))
        await store.close()

        // —— R03 读取契约：历史坏行（负维度 / 短 BLOB）隔离跳过，不崩溃 ——
        let dbPath = root.appendingPathComponent("ThoughtSemanticV3/semantic.sqlite")
        let negativeDimID = UUID()
        let shortBlobID = UUID()
        try injectRawVectorRow(into: dbPath, id: negativeDimID, modelVersion: "m",
                               dimension: -1, vectorKey: 9001, blob: Data([0x00, 0x00]))
        try injectRawVectorRow(into: dbPath, id: shortBlobID, modelVersion: "m",
                               dimension: 1024, vectorKey: 9002, blob: Data([0x00, 0x00]))
        let reopened = await ThoughtSemanticStore(root: root)
        try await reopened.open()
        let rows = try await reopened.loadAllActiveVectors(modelVersion: "m")
        check(rows.count == 1 && rows[0].vector.count == 4, "坏行被隔离，仅合法行返回，实测 \(rows.count) 行")
        check(try await reopened.activeVector(thoughtID: negativeDimID, contentHash: "dirty", modelVersion: "m") == nil,
              "负维度行读取安全拒绝")
        check(try await reopened.loadVector(thoughtID: shortBlobID) == nil, "短 BLOB 行读取安全拒绝")
        check(try await reopened.item(thoughtID: negativeDimID)?.vectorKey == 9001, "元数据行正常读回（key 范围内）")

        // —— R14 打开失败：错误码必须是真实打开结果，不得是关闭后查询所得 MISUSE(21) ——
        let occupied = root.appendingPathComponent("occupied-root")
        try Data("not a directory".utf8).write(to: occupied)
        var probe: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let realRC = sqlite3_open_v2(occupied.appendingPathComponent("ThoughtSemanticV3/semantic.sqlite").path,
                                     &probe, flags, nil)
        if let probe { sqlite3_close_v2(probe) }
        check(realRC != SQLITE_OK && realRC != SQLITE_MISUSE, "探针路径应真实打开失败，rc=\(realRC)")
        let blocked = await ThoughtSemanticStore(root: occupied)
        do {
            try await blocked.open()
            check(false, "目录被文件占据时必须打开失败")
        } catch let error as ThoughtSemanticStore.StoreError {
            guard case .openFailed(let code) = error else {
                check(false, "应为 openFailed，实际 \(error)")
                return
            }
            check(code == realRC, "错误码应为真实打开结果 \(realRC)，实测 \(code)（旧实现关闭后误查恒得 21）")
        }
    }

    /// 绕过生产写入契约直接插坏行（模拟历史脏数据）。仅限本套件临时库使用。
    private static func injectRawVectorRow(into dbPath: URL, id: UUID, contentHash: String = "dirty",
                                           modelVersion: String, dimension: Int32,
                                           vectorKey: Int64, blob: Data) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            preconditionFailure("测试注入库打不开")
        }
        defer { sqlite3_close_v2(db) }
        let sql = """
            INSERT INTO semantic_item(id, thought_id, content_hash, model_version, dimension,
                                      vector_key, state, priority, last_accessed_at, updated_at, vector_f16)
            VALUES(?1, ?1, ?2, ?3, ?4, ?5, 'active', 0, NULL, ?6, ?7)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            preconditionFailure("坏行 prepare 失败")
        }
        defer { sqlite3_finalize(stmt) }
        var uuid = id.uuid
        withUnsafeBytes(of: &uuid) { sqlite3_bind_blob(stmt, 1, $0.baseAddress, 16, transient) }
        sqlite3_bind_text(stmt, 2, contentHash, -1, transient)
        sqlite3_bind_text(stmt, 3, modelVersion, -1, transient)
        sqlite3_bind_int(stmt, 4, dimension)
        sqlite3_bind_int64(stmt, 5, vectorKey)
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 7, $0.baseAddress, Int32(blob.count), transient) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { preconditionFailure("坏行插入失败") }
    }
}
